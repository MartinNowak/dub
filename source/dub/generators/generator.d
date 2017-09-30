/**
	Generator for project files

	Copyright: © 2012-2013 Matthias Dondorff, © 2013-2016 Sönke Ludwig
	License: Subject to the terms of the MIT license, as written in the included LICENSE.txt file.
	Authors: Matthias Dondorff
*/
module dub.generators.generator;

import dub.compilers.compiler;
import dub.generators.cmake;
import dub.generators.build;
import dub.generators.sublimetext;
import dub.generators.visuald;
import dub.internal.vibecompat.core.file;
import dub.internal.vibecompat.core.log;
import dub.internal.vibecompat.inet.path;
import dub.package_;
import dub.packagemanager;
import dub.project;

import std.algorithm : map, filter, canFind, balancedParens;
import std.array : array;
import std.array;
import std.exception;
import std.file;
import std.string;


/**
	Common interface for project generators/builders.
*/
class ProjectGenerator
{
	/** Information about a single binary target.

		A binary target can either be an executable or a static/dynamic library.
		It consists of one or more packages.
	*/
	struct TargetInfo {
		/// The root package of this target
		Package pack;

		/// All packages compiled into this target
		Package[] packages;

		/// The configuration used for building the root package
		string config;

		/** Build settings used to build the target.

			The build settings include all sources of all contained packages.

			Depending on the specific generator implementation, it may be
			necessary to add any static or dynamic libraries generated for
			child targets ($(D linkDependencies)).
		*/
		BuildSettings buildSettings;

		/** List of all dependencies.

			This list includes dependencies that are not the root of a binary
			target.
		*/
		string[] dependencies;

		/** List of all binary dependencies.

			This list includes all dependencies that are the root of a binary
			target.
		*/
		string[] linkDependencies;
	}

	protected {
		Project m_project;
	}

	this(Project project)
	{
		m_project = project;
	}

	/** Performs the full generator process.
	*/
	final void generate(GeneratorSettings settings)
	{
		import dub.compilers.utils : enforceBuildRequirements;

		if (!settings.config.length) settings.config = m_project.getDefaultConfiguration(settings.platform);

		string[string] configs = m_project.getPackageConfigs(settings.platform, settings.config);
		TargetInfo[string] targets;

		foreach (pack; m_project.getTopologicalPackageList(true, null, configs)) {
			BuildSettings buildSettings;
			auto config = configs[pack.name];
			buildSettings.processVars(m_project, pack, pack.getBuildSettings(settings.platform, config), true);
			targets[pack.name] = TargetInfo(pack, [pack], config, buildSettings);

			prepareGeneration(pack, m_project, settings, buildSettings);
		}

		string[] mainfiles = configureTargets(m_project.rootPackage, targets, settings);

		addBuildTypeSettings(targets, settings);
		foreach (ref t; targets.byValue) enforceBuildRequirements(t.buildSettings);
		auto bs = &targets[m_project.rootPackage.name].buildSettings;
		if (bs.targetType == TargetType.executable) bs.addSourceFiles(mainfiles);

		generateTargets(settings, targets);

		foreach (pack; m_project.getTopologicalPackageList(true, null, configs)) {
			BuildSettings buildsettings;
			buildsettings.processVars(m_project, pack, pack.getBuildSettings(settings.platform, configs[pack.name]), true);
			bool generate_binary = !(buildsettings.options & BuildOption.syntaxOnly);
			finalizeGeneration(pack, m_project, settings, buildsettings, Path(bs.targetPath), generate_binary);
		}

		performPostGenerateActions(settings, targets);
	}

	/** Overridden in derived classes to implement the actual generator functionality.

		The function should go through all targets recursively. The first target
		(which is guaranteed to be there) is
		$(D targets[m_project.rootPackage.name]). The recursive descent is then
		done using the $(D TargetInfo.linkDependencies) list.

		This method is also potentially responsible for running the pre and post
		build commands, while pre and post generate commands are already taken
		care of by the $(D generate) method.

		Params:
			settings = The generator settings used for this run
			targets = A map from package name to TargetInfo that contains all
				binary targets to be built.
	*/
	protected abstract void generateTargets(GeneratorSettings settings, in TargetInfo[string] targets);

	/** Overridable method to be invoked after the generator process has finished.

		An examples of functionality placed here is to run the application that
		has just been built.
	*/
	protected void performPostGenerateActions(GeneratorSettings settings, in TargetInfo[string] targets) {}

	/** Configure `rootPackage` and all of it's dependencies.

		1. Merge versions, debugVersions, and inheritable build
		settings from dependents to their dependencies.

		2. Define version identifiers Have_dependency_xyz for all
		direct dependencies of all packages.

		3. Merge versions, debugVersions, and inheritable build settings from
		dependencies to their dependents, so that importer and importee are ABI
		compatible. This also transports all Have_dependency_xyz version
		identifiers to `rootPackage`.

		Note: The upwards inheritance is done at last so that siblings do not
		influence each other, also see https://github.com/dlang/dub/pull/1128.
	 */
	private string[] configureTargets(Package rootPackage, TargetInfo[string] targets, GeneratorSettings genSettings)
	{
		import std.algorithm : remove, sort;

		// 0. do shallow configuration (not including their dependencies) of all packages
		TargetType determineTargetType(const ref TargetInfo ti)
		{
			TargetType tt = ti.buildSettings.targetType;
			if (ti.pack is rootPackage) {
				if (tt == TargetType.autodetect || tt == TargetType.library) tt = TargetType.staticLibrary;
			} else {
				if (tt == TargetType.autodetect || tt == TargetType.library) tt = genSettings.combined ? TargetType.sourceLibrary : TargetType.staticLibrary;
				else if (tt == TargetType.dynamicLibrary) {
					logWarn("Dynamic libraries are not yet supported as dependencies - building as static library.");
					tt = TargetType.staticLibrary;
				}
			}
			if (tt != TargetType.none && tt != TargetType.sourceLibrary && ti.buildSettings.sourceFiles.empty) {
				logWarn(`Configuration '%s' of package %s contains no source files. Please add {"targetType": "none"} to its package description to avoid building it.`,
						ti.config, ti.pack.name);
				tt = TargetType.none;
			}
			return tt;
		}

		string[] mainSourceFiles;
		bool[string] isTarget;

		foreach (ref ti; targets.byValue)
		{
			auto bs = &ti.buildSettings;
			// determine the actual target type
			bs.targetType = determineTargetType(ti);

			switch (bs.targetType)
			{
			case TargetType.none:
				// ignore any build settings for targetType none (only dependencies will be processed)
				*bs = BuildSettings.init;
				break;

			case TargetType.executable:
				break;

			case TargetType.dynamicLibrary:
				// set -fPIC for dynamic library builds
				ti.buildSettings.addOptions(BuildOption.pic);
				goto default;

			default:
				// remove any mainSourceFile from non-executable builds
				bs.sourceFiles = bs.sourceFiles.remove!(f => f == bs.mainSourceFile);
				mainSourceFiles ~= bs.mainSourceFile;
				break;
			}
			bool generatesBinary = bs.targetType != TargetType.sourceLibrary && bs.targetType != TargetType.none;
			isTarget[ti.pack.name] = generatesBinary || ti.pack is rootPackage;
		}

		void[0][Package] visited;

		// collect all dependencies and
		void collectDependencies(Package pack, ref TargetInfo ti, TargetInfo[string] targets, size_t level = 0)
		{
			import dub.compilers.utils : isLinkerFile;

			if (pack in visited)
				return;
			visited[pack] = typeof(visited[pack]).init;

			auto bs = &ti.buildSettings;
			static immutable spcs = "                                        ";
			if (isTarget[pack.name])
				logDiagnostic("%sConfiguring target %s (%s %s %s)", spcs[0 .. 2 * level], pack.name, bs.targetType, bs.targetPath, bs.targetName);
			else
				logDiagnostic("%sConfiguring non-build target %s", spcs[0 .. 2 * level], pack.name);

			// get specified dependencies, e.g. vibe-d ~0.8.1
			auto deps = pack.getDependencies(targets[pack.name].config);
			logDiagnostic("deps: %s -> %(%s, %)", pack.name, deps.byKey);
			foreach (depname; deps.keys.sort())
			{
				auto depspec = deps[depname];
				// get selected package for that dependency, e.g. vibe-d 0.8.2-beta.2
				auto deppack = m_project.getDependency(depname, depspec.optional);
				if (deppack is null) continue; // optional and not selected

				// if dependency is not a target itself
				if (!isTarget[depname]) {
					// add itself
					ti.packages ~= deppack;
					// and it's transitive dependencies to current target
					collectDependencies(deppack, ti, targets, level + 1);
					continue;
				}
				auto depti = &targets[depname];
				auto depbs = &depti.buildSettings;
				// replace dependency sources with their binary files
				depbs.sourceFiles = depbs.sourceFiles.filter!(f => f.isLinkerFile()).array;
				depbs.importFiles = null;
				if (depbs.targetType == TargetType.executable)
					continue;
				// add to (link) dependencies
				ti.dependencies ~= depname;
				ti.linkDependencies ~= depname;
				// also add all link dependencies of static libraries
				if (depbs.targetType == TargetType.staticLibrary)
					ti.linkDependencies = ti.linkDependencies.filter!(d => !depti.linkDependencies.canFind(d)).array ~ depti.linkDependencies;

				// recurse
				collectDependencies(deppack, *depti, targets, level + 1);
			}
		}

		collectDependencies(rootPackage, targets[rootPackage.name], targets);

		// 1. downwards inherits versions, debugVersions, and inheritable build settings
		static void inherit(in ref TargetInfo ti, TargetInfo[string] targets, size_t level = 0)
		{
			static immutable spcs = "                                        ";
			logDiagnostic("%sInherit configuration %s", spcs[0 .. 2 * level], ti.pack.name);
			foreach (depname; ti.dependencies)
			{
				auto pti = &targets[depname];
				inheritConfiguration(ti.buildSettings, pti.buildSettings);
				inherit(*pti, targets, level + 1);
			}
		}

		inherit(targets[rootPackage.name], targets);

		// 2. add Have_dependency_xyz for all direct dependencies of a target
		// (includes incorporated non-target dependencies and their dependencies)
		foreach (ref ti; targets.byValue)
		{
			import std.range : chain;
			import dub.internal.utils : stripDlangSpecialChars;

			auto bs = &ti.buildSettings;
			auto depnames = ti.packages.map!(p => p.name).chain(ti.dependencies);
			bs.addVersions(depnames.map!(pn => "Have_" ~ stripDlangSpecialChars(pn)).array);
		}

		// 3. upwards inherit full build configurations (import paths, versions, debugVersions, ...)
		static void configureDependents(ref TargetInfo ti, TargetInfo[string] targets, size_t level = 0)
		{
			static immutable spcs = "                                        ";
			logDiagnostic("%sConfiguring dependents %s %(%s, %)", spcs[0 .. 2 * level], ti.pack.name, ti.dependencies);
			// binary dependencies
			foreach (depname; ti.dependencies)
			{
				auto pdepti = &targets[depname];
				configureDependents(*pdepti, targets, level + 1);
				ti.buildSettings.add(pdepti.buildSettings);
			}
			// non-build dependencies
			foreach (deppack; ti.packages)
				ti.buildSettings.add(targets[deppack.name].buildSettings);
		}

		configureDependents(targets[rootPackage.name], targets);

		// 4. override string import files in dependents
		auto rootbs = &targets[rootPackage.name].buildSettings;
		foreach (ref ti; targets.byValue)
			if (ti.pack !is rootPackage)
				overrideStringImports(*rootbs, ti.buildSettings);

		// remove non-build packages from targets
		foreach (name; targets.keys)
		{
			if (name !in isTarget)
				targets.remove(name);
		}

		return mainSourceFiles;
	}

	private static void inheritConfiguration(in ref BuildSettings parent, ref BuildSettings child)
	{
		child.addVersions(parent.versions);
		child.addDebugVersions(parent.debugVersions);
		child.addOptions(BuildOptions(cast(BuildOptions)parent.options & inheritedBuildOptions));
	}

	private static void overrideStringImports(in ref BuildSettings rootbs, ref BuildSettings childbs)
	{
		// special support for overriding string imports in parent packages
		// this is a candidate for deprecation, once an alternative approach
		// has been found
		if (childbs.stringImportPaths.length) {
			// override string import files (used for up to date checking)
			foreach (ref f; childbs.stringImportFiles)
				foreach (fi; rootbs.stringImportFiles)
					if (f != fi && Path(f).head == Path(fi).head) {
						f = fi;
					}

			// add the string import paths (used by the compiler to find the overridden files)
			childbs.prependStringImportPaths(rootbs.stringImportPaths);
		}
	}

	// configure targets for build types such as release, or unittest-cov
	private void addBuildTypeSettings(TargetInfo[string] targets, GeneratorSettings settings)
	{
		foreach (ref ti; targets.byValue) {
			ti.buildSettings.add(settings.buildSettings);

			// add build type settings and convert plain DFLAGS to build options
			m_project.addBuildTypeSettings(ti.buildSettings, settings.platform, settings.buildType, ti.pack is m_project.rootPackage);
			settings.compiler.extractBuildOptions(ti.buildSettings);

			auto tt = ti.buildSettings.targetType;
			bool generatesBinary = tt != TargetType.sourceLibrary && tt != TargetType.none;
			enforce (generatesBinary || ti.pack !is m_project.rootPackage || (ti.buildSettings.options & BuildOption.syntaxOnly),
				format("Main package must have a binary target type, not %s. Cannot build.", tt));
		}
	}
}


struct GeneratorSettings {
	BuildPlatform platform;
	Compiler compiler;
	string config;
	string buildType;
	BuildSettings buildSettings;
	BuildMode buildMode = BuildMode.separate;

	bool combined; // compile all in one go instead of each dependency separately

	// only used for generator "build"
	bool run, force, direct, rdmd, tempBuild, parallelBuild;
	string[] runArgs;
	void delegate(int status, string output) compileCallback;
	void delegate(int status, string output) linkCallback;
	void delegate(int status, string output) runCallback;
}


/**
	Determines the mode in which the compiler and linker are invoked.
*/
enum BuildMode {
	separate,                 /// Compile and link separately
	allAtOnce,                /// Perform compile and link with a single compiler invocation
	singleFile,               /// Compile each file separately
	//multipleObjects,          /// Generate an object file per module
	//multipleObjectsPerModule, /// Use the -multiobj switch to generate multiple object files per module
	//compileOnly               /// Do not invoke the linker (can be done using a post build command)
}


/**
	Creates a project generator of the given type for the specified project.
*/
ProjectGenerator createProjectGenerator(string generator_type, Project project)
{
	assert(project !is null, "Project instance needed to create a generator.");

	generator_type = generator_type.toLower();
	switch(generator_type) {
		default:
			throw new Exception("Unknown project generator: "~generator_type);
		case "build":
			logDebug("Creating build generator.");
			return new BuildGenerator(project);
		case "mono-d":
			throw new Exception("The Mono-D generator has been removed. Use Mono-D's built in DUB support instead.");
		case "visuald":
			logDebug("Creating VisualD generator.");
			return new VisualDGenerator(project);
		case "sublimetext":
			logDebug("Creating SublimeText generator.");
			return new SublimeTextGenerator(project);
		case "cmake":
			logDebug("Creating CMake generator.");
			return new CMakeGenerator(project);
	}
}


/**
	Runs pre-build commands and performs other required setup before project files are generated.
*/
private void prepareGeneration(in Package pack, in Project proj, in GeneratorSettings settings,
	in BuildSettings buildsettings)
{
	if (buildsettings.preGenerateCommands.length && !isRecursiveInvocation(pack.name)) {
		logInfo("Running pre-generate commands for %s...", pack.name);
		runBuildCommands(buildsettings.preGenerateCommands, pack, proj, settings, buildsettings);
	}
}

/**
	Runs post-build commands and copies required files to the binary directory.
*/
private void finalizeGeneration(in Package pack, in Project proj, in GeneratorSettings settings,
	in BuildSettings buildsettings, Path target_path, bool generate_binary)
{
	import std.path : globMatch;

	if (buildsettings.postGenerateCommands.length && !isRecursiveInvocation(pack.name)) {
		logInfo("Running post-generate commands for %s...", pack.name);
		runBuildCommands(buildsettings.postGenerateCommands, pack, proj, settings, buildsettings);
	}

	if (generate_binary) {
		if (!exists(buildsettings.targetPath))
			mkdirRecurse(buildsettings.targetPath);

		if (buildsettings.copyFiles.length) {
			void copyFolderRec(Path folder, Path dstfolder)
			{
				mkdirRecurse(dstfolder.toNativeString());
				foreach (de; iterateDirectory(folder.toNativeString())) {
					if (de.isDirectory) {
						copyFolderRec(folder ~ de.name, dstfolder ~ de.name);
					} else {
						try hardLinkFile(folder ~ de.name, dstfolder ~ de.name, true);
						catch (Exception e) {
							logWarn("Failed to copy file %s: %s", (folder ~ de.name).toNativeString(), e.msg);
						}
					}
				}
			}

			void tryCopyDir(string file)
			{
				auto src = Path(file);
				if (!src.absolute) src = pack.path ~ src;
				auto dst = target_path ~ Path(file).head;
				if (src == dst) {
					logDiagnostic("Skipping copy of %s (same source and destination)", file);
					return;
				}
				logDiagnostic("  %s to %s", src.toNativeString(), dst.toNativeString());
				try {
					copyFolderRec(src, dst);
				} catch(Exception e) logWarn("Failed to copy %s to %s: %s", src.toNativeString(), dst.toNativeString(), e.msg);
			}

			void tryCopyFile(string file)
			{
				auto src = Path(file);
				if (!src.absolute) src = pack.path ~ src;
				auto dst = target_path ~ Path(file).head;
				if (src == dst) {
					logDiagnostic("Skipping copy of %s (same source and destination)", file);
					return;
				}
				logDiagnostic("  %s to %s", src.toNativeString(), dst.toNativeString());
				try {
					hardLinkFile(src, dst, true);
				} catch(Exception e) logWarn("Failed to copy %s to %s: %s", src.toNativeString(), dst.toNativeString(), e.msg);
			}
			logInfo("Copying files for %s...", pack.name);
			string[] globs;
			foreach (f; buildsettings.copyFiles)
			{
				if (f.canFind("*", "?") ||
					(f.canFind("{") && f.balancedParens('{', '}')) ||
					(f.canFind("[") && f.balancedParens('[', ']')))
				{
					globs ~= f;
				}
				else
				{
					if (f.isDir)
						tryCopyDir(f);
					else
						tryCopyFile(f);
				}
			}
			if (globs.length) // Search all files for glob matches
			{
				foreach (f; dirEntries(pack.path.toNativeString(), SpanMode.breadth))
				{
					foreach (glob; globs)
					{
						if (f.name().globMatch(glob))
						{
							if (f.isDir)
								tryCopyDir(f);
							else
								tryCopyFile(f);
							break;
						}
					}
				}
			}
		}

	}
}


/** Runs a list of build commands for a particular package.

	This function sets all DUB speficic environment variables and makes sure
	that recursive dub invocations are detected and don't result in infinite
	command execution loops. The latter could otherwise happen when a command
	runs "dub describe" or similar functionality.
*/
void runBuildCommands(in string[] commands, in Package pack, in Project proj,
	in GeneratorSettings settings, in BuildSettings build_settings)
{
	import std.conv;
	import std.process;
	import dub.internal.utils;

	string[string] env = environment.toAA();
	// TODO: do more elaborate things here
	// TODO: escape/quote individual items appropriately
	env["DFLAGS"]                = join(cast(string[])build_settings.dflags, " ");
	env["LFLAGS"]                = join(cast(string[])build_settings.lflags," ");
	env["VERSIONS"]              = join(cast(string[])build_settings.versions," ");
	env["LIBS"]                  = join(cast(string[])build_settings.libs," ");
	env["IMPORT_PATHS"]          = join(cast(string[])build_settings.importPaths," ");
	env["STRING_IMPORT_PATHS"]   = join(cast(string[])build_settings.stringImportPaths," ");

	env["DC"]                    = settings.platform.compilerBinary;
	env["DC_BASE"]               = settings.platform.compiler;
	env["D_FRONTEND_VER"]        = to!string(settings.platform.frontendVersion);

	env["DUB_PLATFORM"]          = join(cast(string[])settings.platform.platform," ");
	env["DUB_ARCH"]              = join(cast(string[])settings.platform.architecture," ");

	env["DUB_TARGET_TYPE"]       = to!string(build_settings.targetType);
	env["DUB_TARGET_PATH"]       = build_settings.targetPath;
	env["DUB_TARGET_NAME"]       = build_settings.targetName;
	env["DUB_WORKING_DIRECTORY"] = build_settings.workingDirectory;
	env["DUB_MAIN_SOURCE_FILE"]  = build_settings.mainSourceFile;

	env["DUB_CONFIG"]            = settings.config;
	env["DUB_BUILD_TYPE"]        = settings.buildType;
	env["DUB_BUILD_MODE"]        = to!string(settings.buildMode);
	env["DUB_PACKAGE"]           = pack.name;
	env["DUB_PACKAGE_DIR"]       = pack.path.toNativeString();
	env["DUB_ROOT_PACKAGE"]      = proj.rootPackage.name;
	env["DUB_ROOT_PACKAGE_DIR"]  = proj.rootPackage.path.toNativeString();

	env["DUB_COMBINED"]          = settings.combined?      "TRUE" : "";
	env["DUB_RUN"]               = settings.run?           "TRUE" : "";
	env["DUB_FORCE"]             = settings.force?         "TRUE" : "";
	env["DUB_DIRECT"]            = settings.direct?        "TRUE" : "";
	env["DUB_RDMD"]              = settings.rdmd?          "TRUE" : "";
	env["DUB_TEMP_BUILD"]        = settings.tempBuild?     "TRUE" : "";
	env["DUB_PARALLEL_BUILD"]    = settings.parallelBuild? "TRUE" : "";

	env["DUB_RUN_ARGS"] = (cast(string[])settings.runArgs).map!(escapeShellFileName).join(" ");

	auto depNames = proj.dependencies.map!((a) => a.name).array();
	storeRecursiveInvokations(env, proj.rootPackage.name ~ depNames);
	runCommands(commands, env);
}

private bool isRecursiveInvocation(string pack)
{
	import std.algorithm : canFind, splitter;
	import std.process : environment;

	return environment
        .get("DUB_PACKAGES_USED", "")
        .splitter(",")
        .canFind(pack);
}

private void storeRecursiveInvokations(string[string] env, string[] packs)
{
	import std.algorithm : canFind, splitter;
	import std.range : chain;
	import std.process : environment;

    env["DUB_PACKAGES_USED"] = environment
        .get("DUB_PACKAGES_USED", "")
        .splitter(",")
        .chain(packs)
        .join(",");
}
