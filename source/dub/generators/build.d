/**
	Generator for direct compiler builds.

	Copyright: © 2013-2013 rejectedsoftware e.K.
	License: Subject to the terms of the MIT license, as written in the included LICENSE.txt file.
	Authors: Sönke Ludwig
*/
module dub.generators.build;

import dub.compilers.compiler;
import dub.generators.generator;
import dub.internal.utils;
import dub.internal.vibecompat.core.file;
import dub.internal.vibecompat.core.log;
import dub.internal.vibecompat.inet.path;
import dub.package_;
import dub.packagemanager;
import dub.project;

import std.algorithm;
import std.array;
import std.conv;
import std.exception;
import std.file;
import std.process;
import std.string;
import std.encoding : sanitize;

version(Windows) enum objSuffix = ".obj";
else enum objSuffix = ".o";

class BuildGenerator : ProjectGenerator {
	private {
		PackageManager m_packageMan;
		Path[] m_temporaryFiles;
	}

	this(Project project)
	{
		super(project);
		m_packageMan = project.packageManager;
	}

	override void generateTargets(GeneratorSettings settings, in TargetInfo[string] targets)
	{
		scope (exit) cleanupTemporaries();

		bool[string] visited;
		void buildTargetRec(string target)
		{
			if (target in visited) return;
			visited[target] = true;

			auto ti = targets[target];

			foreach (dep; ti.dependencies)
				buildTargetRec(dep);

			Path[] additional_dep_files;
			auto bs = ti.buildSettings.dup;
			foreach (ldep; ti.linkDependencies) {
				auto dbs = targets[ldep].buildSettings;
				if (bs.targetType != TargetType.staticLibrary) {
					bs.addSourceFiles((Path(dbs.targetPath) ~ getTargetFileName(dbs, settings.platform)).toNativeString());
				} else {
					additional_dep_files ~= Path(dbs.targetPath) ~ getTargetFileName(dbs, settings.platform);
				}
			}
			buildTarget(settings, bs, ti.pack, ti.config, ti.packages, additional_dep_files);
		}

		// build all targets
		auto root_ti = targets[m_project.rootPackage.name];
		if (settings.rdmd || root_ti.buildSettings.targetType == TargetType.staticLibrary) {
			// RDMD always builds everything at once and static libraries don't need their
			// dependencies to be built
			buildTarget(settings, root_ti.buildSettings.dup, m_project.rootPackage, root_ti.config, root_ti.packages, null);
		} else buildTargetRec(m_project.rootPackage.name);
	}

	override void performPostGenerateActions(GeneratorSettings settings, in TargetInfo[string] targets)
	{
		// run the generated executable
		auto buildsettings = targets[m_project.rootPackage.name].buildSettings;
		if (settings.run && !(buildsettings.options & BuildOption.syntaxOnly)) {
			if (buildsettings.targetType != TargetType.executable) {
				enforce(false, "Target is a library. Skipping execution.");
				return;
			}
			auto exe_file_path = Path(buildsettings.targetPath) ~ getTargetFileName(buildsettings, settings.platform);
			if (settings.watch)
				watchTarget(exe_file_path, buildsettings, settings.runArgs, settings, targets);
			else
				runTarget(exe_file_path, buildsettings, settings.runArgs, settings);
		}
	}

	private void buildTarget(GeneratorSettings settings, BuildSettings buildsettings, in Package pack, string config, in Package[] packages, in Path[] additional_dep_files)
	{
		auto cwd = Path(getcwd());
		bool generate_binary = !(buildsettings.options & BuildOption.syntaxOnly);

		auto build_id = computeBuildID(config, buildsettings, settings);

		// make all paths relative to shrink the command line
		string makeRelative(string path) { auto p = Path(path); if (p.absolute) p = p.relativeTo(cwd); return p.toNativeString(); }
		foreach (ref f; buildsettings.sourceFiles) f = makeRelative(f);
		foreach (ref p; buildsettings.importPaths) p = makeRelative(p);
		foreach (ref p; buildsettings.stringImportPaths) p = makeRelative(p);

		// perform the actual build
		bool cached = false;
		if (settings.rdmd) performRDMDBuild(settings, buildsettings, pack, config);
		else if (settings.direct || !generate_binary) performDirectBuild(settings, buildsettings, pack, config);
		else cached = performCachedBuild(settings, buildsettings, pack, config, build_id, packages, additional_dep_files);

		// run post-build commands
		if (!cached && buildsettings.postBuildCommands.length) {
			logInfo("Running post-build commands...");
			runBuildCommands(buildsettings.postBuildCommands, buildsettings);
		}
	}

	bool performCachedBuild(GeneratorSettings settings, BuildSettings buildsettings, in Package pack, string config, string build_id, in Package[] packages, in Path[] additional_dep_files)
	{
		auto cwd = Path(getcwd());
		auto target_path = pack.path ~ format(".dub/build/%s/", build_id);

		if (!settings.force && isUpToDate(target_path, buildsettings, settings.platform, pack, packages, additional_dep_files)) {
			logInfo("Target %s %s is up to date. Use --force to rebuild.", pack.name, pack.vers);
			logDiagnostic("Using existing build in %s.", target_path.toNativeString());
			copyTargetFile(target_path, buildsettings, settings.platform);
			return true;
		}

		if (settings.tempBuild || !isWritableDir(target_path, true)) {
			if (!settings.tempBuild)
				logInfo("Build directory %s is not writable. Falling back to direct build in the system's temp folder.", target_path.relativeTo(cwd).toNativeString());
			performDirectBuild(settings, buildsettings, pack, config);
			return false;
		}

		// determine basic build properties
		auto generate_binary = !(buildsettings.options & BuildOption.syntaxOnly);

		logInfo("Building %s %s configuration \"%s\", build type %s.", pack.name, pack.vers, config, settings.buildType);

		if( buildsettings.preBuildCommands.length ){
			logInfo("Running pre-build commands...");
			runBuildCommands(buildsettings.preBuildCommands, buildsettings);
		}

		// override target path
		auto cbuildsettings = buildsettings;
		cbuildsettings.targetPath = target_path.relativeTo(cwd).toNativeString();
		buildWithCompiler(settings, cbuildsettings);

		copyTargetFile(target_path, buildsettings, settings.platform);

		return false;
	}

	void performRDMDBuild(GeneratorSettings settings, ref BuildSettings buildsettings, in Package pack, string config)
	{
		auto cwd = Path(getcwd());
		//Added check for existance of [AppNameInPackagejson].d
		//If exists, use that as the starting file.
		Path mainsrc;
		if (buildsettings.mainSourceFile.length) {
			mainsrc = Path(buildsettings.mainSourceFile);
			if (!mainsrc.absolute) mainsrc = pack.path ~ mainsrc;
		} else {
			mainsrc = getMainSourceFile(pack);
			logWarn(`Package has no "mainSourceFile" defined. Using best guess: %s`, mainsrc.relativeTo(pack.path).toNativeString());
		}

		// do not pass all source files to RDMD, only the main source file
		buildsettings.sourceFiles = buildsettings.sourceFiles.filter!(s => !s.endsWith(".d"))().array();
		settings.compiler.prepareBuildSettings(buildsettings, BuildSetting.commandLine);

		auto generate_binary = !buildsettings.dflags.canFind("-o-");

		// Create start script, which will be used by the calling bash/cmd script.
		// build "rdmd --force %DFLAGS% -I%~dp0..\source -Jviews -Isource @deps.txt %LIBS% source\app.d" ~ application arguments
		// or with "/" instead of "\"
		Path exe_file_path;
		bool tmp_target = false;
		if (generate_binary) {
			if (settings.tempBuild || (settings.run && !isWritableDir(Path(buildsettings.targetPath), true))) {
				import std.random;
				auto rnd = to!string(uniform(uint.min, uint.max)) ~ "-";
				auto tmpdir = getTempDir()~".rdmd/source/";
				buildsettings.targetPath = tmpdir.toNativeString();
				buildsettings.targetName = rnd ~ buildsettings.targetName;
				m_temporaryFiles ~= tmpdir;
				tmp_target = true;
			}
			exe_file_path = Path(buildsettings.targetPath) ~ getTargetFileName(buildsettings, settings.platform);
			settings.compiler.setTarget(buildsettings, settings.platform);
		}

		logDiagnostic("Application output name is '%s'", getTargetFileName(buildsettings, settings.platform));

		string[] flags = ["--build-only", "--compiler="~settings.platform.compilerBinary];
		if (settings.force) flags ~= "--force";
		flags ~= buildsettings.dflags;
		flags ~= mainsrc.relativeTo(cwd).toNativeString();

		if (buildsettings.preBuildCommands.length){
			logInfo("Running pre-build commands...");
			runCommands(buildsettings.preBuildCommands);
		}

		logInfo("Building configuration "~config~", build type "~settings.buildType);

		logInfo("Running rdmd...");
		logDiagnostic("rdmd %s", join(flags, " "));
		auto rdmd_pid = spawnProcess("rdmd" ~ flags);
		auto result = rdmd_pid.wait();
		enforce(result == 0, "Build command failed with exit code "~to!string(result));

		if (tmp_target) {
			m_temporaryFiles ~= exe_file_path;
			foreach (f; buildsettings.copyFiles)
				m_temporaryFiles ~= Path(buildsettings.targetPath).parentPath ~ Path(f).head;
		}
	}

	void performDirectBuild(GeneratorSettings settings, ref BuildSettings buildsettings, in Package pack, string config)
	{
		auto cwd = Path(getcwd());

		auto generate_binary = !(buildsettings.options & BuildOption.syntaxOnly);
		auto is_static_library = buildsettings.targetType == TargetType.staticLibrary || buildsettings.targetType == TargetType.library;

		// make file paths relative to shrink the command line
		foreach (ref f; buildsettings.sourceFiles) {
			auto fp = Path(f);
			if( fp.absolute ) fp = fp.relativeTo(cwd);
			f = fp.toNativeString();
		}

		logInfo("Building configuration \""~config~"\", build type "~settings.buildType);

		// make all target/import paths relative
		string makeRelative(string path) { auto p = Path(path); if (p.absolute) p = p.relativeTo(cwd); return p.toNativeString(); }
		buildsettings.targetPath = makeRelative(buildsettings.targetPath);
		foreach (ref p; buildsettings.importPaths) p = makeRelative(p);
		foreach (ref p; buildsettings.stringImportPaths) p = makeRelative(p);

		Path exe_file_path;
		bool is_temp_target = false;
		if (generate_binary) {
			if (settings.tempBuild || (settings.run && !isWritableDir(Path(buildsettings.targetPath), true))) {
				import std.random;
				auto rnd = to!string(uniform(uint.min, uint.max));
				auto tmppath = getTempDir()~("dub/"~rnd~"/");
				buildsettings.targetPath = tmppath.toNativeString();
				m_temporaryFiles ~= tmppath;
				is_temp_target = true;
			}
			exe_file_path = Path(buildsettings.targetPath) ~ getTargetFileName(buildsettings, settings.platform);
		}

		if( buildsettings.preBuildCommands.length ){
			logInfo("Running pre-build commands...");
			runBuildCommands(buildsettings.preBuildCommands, buildsettings);
		}

		buildWithCompiler(settings, buildsettings);

		if (is_temp_target) {
			m_temporaryFiles ~= exe_file_path;
			foreach (f; buildsettings.copyFiles)
				m_temporaryFiles ~= Path(buildsettings.targetPath).parentPath ~ Path(f).head;
		}
	}

	private string computeBuildID(string config, in BuildSettings buildsettings, GeneratorSettings settings)
	{
		import std.digest.digest;
		import std.digest.md;
		import std.bitmanip;

		MD5 hash;
		hash.start();
		void addHash(in string[] strings...) { foreach (s; strings) { hash.put(cast(ubyte[])s); hash.put(0); } hash.put(0); }
		void addHashI(int value) { hash.put(nativeToLittleEndian(value)); }
		addHash(buildsettings.versions);
		addHash(buildsettings.debugVersions);
		//addHash(buildsettings.versionLevel);
		//addHash(buildsettings.debugLevel);
		addHash(buildsettings.dflags);
		addHash(buildsettings.lflags);
		addHash((cast(uint)buildsettings.options).to!string);
		addHash(buildsettings.stringImportPaths);
		addHash(settings.platform.architecture);
		addHash(settings.platform.compilerBinary);
		addHash(settings.platform.compiler);
		addHashI(settings.platform.frontendVersion);
		auto hashstr = hash.finish().toHexString().idup;

		return format("%s-%s-%s-%s-%s_%s-%s", config, settings.buildType,
			settings.platform.platform.join("."),
			settings.platform.architecture.join("."),
			settings.platform.compiler, settings.platform.frontendVersion, hashstr);
	}

	private void copyTargetFile(Path build_path, BuildSettings buildsettings, BuildPlatform platform)
	{
		auto filename = getTargetFileName(buildsettings, platform);
		auto src = build_path ~ filename;
		logDiagnostic("Copying target from %s to %s", src.toNativeString(), buildsettings.targetPath);
		if (!existsFile(Path(buildsettings.targetPath)))
			mkdirRecurse(buildsettings.targetPath);
		hardLinkFile(src, Path(buildsettings.targetPath) ~ filename, true);
	}

	private bool isUpToDate(Path target_path, BuildSettings buildsettings, BuildPlatform platform, in Package main_pack, in Package[] packages, in Path[] additional_dep_files)
	{
		import std.datetime;

		auto targetfile = target_path ~ getTargetFileName(buildsettings, platform);
		if (!existsFile(targetfile)) {
			logDiagnostic("Target '%s' doesn't exist, need rebuild.", targetfile.toNativeString());
			return false;
		}
		auto targettime = getFileInfo(targetfile).timeModified;

		auto allfiles = appender!(string[]);
		allfiles ~= buildsettings.sourceFiles;
		allfiles ~= buildsettings.importFiles;
		allfiles ~= buildsettings.stringImportFiles;
		// TODO: add library files
		foreach (p; packages)
			allfiles ~= (p.packageInfoFilename != Path.init ? p : p.basePackage).packageInfoFilename.toNativeString();
		foreach (f; additional_dep_files) allfiles ~= f.toNativeString();
		if (main_pack is m_project.rootPackage)
			allfiles ~= (main_pack.path ~ SelectedVersions.defaultFile).toNativeString();

		foreach (file; allfiles.data) {
			if (!existsFile(file)) {
				logDiagnostic("File %s doesn't exists, triggering rebuild.", file);
				return false;
			}
			auto ftime = getFileInfo(file).timeModified;
			if (ftime > Clock.currTime)
				logWarn("File '%s' was modified in the future. Please re-save.", file);
			if (ftime > targettime) {
				logDiagnostic("File '%s' modified, need rebuild.", file);
				return false;
			}
		}
		return true;
	}

	/// Output an unique name to represent the source file.
	/// Calls with path that resolve to the same file on the filesystem will return the same,
	/// unless they include different symbolic links (which are not resolved).

	static string pathToObjName(string path)
	{
		import std.path : buildNormalizedPath, dirSeparator, stripDrive;
		return stripDrive(buildNormalizedPath(getcwd(), path~objSuffix))[1..$].replace(dirSeparator, ".");
	}

	/// Compile a single source file (srcFile), and write the object to objName.
	static string compileUnit(string srcFile, string objName, BuildSettings bs, GeneratorSettings gs) {
		Path tempobj = Path(bs.targetPath)~objName;
		string objPath = tempobj.toNativeString();
		bs.libs = null;
		bs.lflags = null;
		bs.sourceFiles = [ srcFile ];
		bs.targetType = TargetType.object;
		gs.compiler.prepareBuildSettings(bs, BuildSetting.commandLine);
		gs.compiler.setTarget(bs, gs.platform, objPath);
		gs.compiler.invoke(bs, gs.platform, gs.compileCallback);
		return objPath;
	}

	void buildWithCompiler(GeneratorSettings settings, BuildSettings buildsettings)
	{
		auto generate_binary = !(buildsettings.options & BuildOption.syntaxOnly);
		auto is_static_library = buildsettings.targetType == TargetType.staticLibrary || buildsettings.targetType == TargetType.library;

		Path target_file;
		scope (failure) {
			logInfo("FAIL %s %s %s" , buildsettings.targetPath, buildsettings.targetName, buildsettings.targetType);
			auto tpath = Path(buildsettings.targetPath) ~ getTargetFileName(buildsettings, settings.platform);
			if (generate_binary && existsFile(tpath))
				removeFile(tpath);
		}
		if (settings.buildMode == BuildMode.singleFile && generate_binary) {
			import std.parallelism, std.range : walkLength;

			auto lbuildsettings = buildsettings;
			auto srcs = buildsettings.sourceFiles.filter!(f => !isLinkerFile(f));
			auto objs = new string[](srcs.walkLength);
			logInfo("Compiling using %s...", settings.platform.compilerBinary);

			void compileSource(size_t i, string src) {
				logInfo("Compiling %s...", src);
				objs[i] = compileUnit(src, pathToObjName(src), buildsettings, settings);
			}

			if (settings.parallelBuild) {
				foreach (i, src; srcs.parallel(1)) compileSource(i, src);
			} else {
				foreach (i, src; srcs.array) compileSource(i, src);
			}

			logInfo("Linking...");
			lbuildsettings.sourceFiles = is_static_library ? [] : lbuildsettings.sourceFiles.filter!(f=> f.isLinkerFile()).array;
			settings.compiler.setTarget(lbuildsettings, settings.platform);
			settings.compiler.prepareBuildSettings(lbuildsettings, BuildSetting.commandLineSeparate|BuildSetting.sourceFiles);
			settings.compiler.invokeLinker(lbuildsettings, settings.platform, objs, settings.linkCallback);

		/*
			NOTE: for DMD experimental separate compile/link is used, but this is not yet implemented
				  on the other compilers. Later this should be integrated somehow in the build process
				  (either in the dub.json, or using a command line flag)
		*/
		} else if (settings.buildMode == BuildMode.allAtOnce || settings.platform.compilerBinary != "dmd" || !generate_binary || is_static_library) {
			// setup for command line
			if (generate_binary) settings.compiler.setTarget(buildsettings, settings.platform);
			settings.compiler.prepareBuildSettings(buildsettings, BuildSetting.commandLine);

			// don't include symbols of dependencies (will be included by the top level target)
			if (is_static_library) buildsettings.sourceFiles = buildsettings.sourceFiles.filter!(f => !f.isLinkerFile()).array;

			// invoke the compiler
			logInfo("Running %s...", settings.platform.compilerBinary);
			settings.compiler.invoke(buildsettings, settings.platform, settings.compileCallback);
		} else {
			// determine path for the temporary object file
			string tempobjname = buildsettings.targetName ~ objSuffix;
			Path tempobj = Path(buildsettings.targetPath) ~ tempobjname;

			// setup linker command line
			auto lbuildsettings = buildsettings;
			lbuildsettings.sourceFiles = lbuildsettings.sourceFiles.filter!(f => isLinkerFile(f)).array;
			settings.compiler.setTarget(lbuildsettings, settings.platform);
			settings.compiler.prepareBuildSettings(lbuildsettings, BuildSetting.commandLineSeparate|BuildSetting.sourceFiles);

			// setup compiler command line
			buildsettings.libs = null;
			buildsettings.lflags = null;
			buildsettings.addDFlags("-c", "-of"~tempobj.toNativeString());
			buildsettings.sourceFiles = buildsettings.sourceFiles.filter!(f => !isLinkerFile(f)).array;
			settings.compiler.prepareBuildSettings(buildsettings, BuildSetting.commandLine);

			logInfo("Compiling using %s...", settings.platform.compilerBinary);
			settings.compiler.invoke(buildsettings, settings.platform, settings.compileCallback);

			logInfo("Linking...");
			settings.compiler.invokeLinker(lbuildsettings, settings.platform, [tempobj.toNativeString()], settings.linkCallback);
		}
	}

	// running and watching

	private Path switchWorkDir(Path cwd, string workDir)
	{
		if (!workDir.length)
			return cwd;
		auto res = Path(workDir);
		if (!res.absolute) res = cwd ~ res;
		logDiagnostic("Switching to %s", res.toNativeString());
		chdir(res.toNativeString());
		return res;
	}

	private string[] runCmd(Path exe_file_path, Path cwd, Path runcwd, string[] run_args)
	{
		if (!exe_file_path.absolute) exe_file_path = cwd ~ exe_file_path;
		auto exe_path_string = exe_file_path.relativeTo(runcwd).toNativeString();
		version (Posix) {
			if (!exe_path_string.startsWith(".") && !exe_path_string.startsWith("/"))
				exe_path_string = "./" ~ exe_path_string;
		}
		version (Windows) {
			if (!exe_path_string.startsWith(".") && (exe_path_string.length < 2 || exe_path_string[1] != ':'))
				exe_path_string = ".\\" ~ exe_path_string;
		}
		return exe_path_string ~ run_args;
	}

	private void runTarget(Path exe_file_path, in BuildSettings buildsettings, string[] run_args, GeneratorSettings settings)
	{
		auto cwd = Path(getcwd());
		auto runcwd = switchWorkDir(cwd, buildsettings.workingDirectory);
		scope(exit) chdir(cwd.toNativeString());

		auto cmd = runCmd(exe_file_path, cwd, runcwd, run_args);
		logInfo("Running '%-(%s %)'", cmd);

		if (settings.runCallback) {
			auto res = execute(cmd);
			settings.runCallback(res.status, res.output);
		} else {
			auto prg_pid = spawnProcess(cmd);
			auto result = prg_pid.wait();
			enforce(result == 0, "Program exited with code "~to!string(result));
		}
	}

	private void watchTarget(Path exe_file_path, in BuildSettings buildsettings, string[] run_args, GeneratorSettings settings, in TargetInfo[string] targets)
	{
		Watcher w;
		logInfo("Setting up file watches.");
		foreach (_, tgt; targets)
		{
			auto bs = tgt.buildSettings;
			import std.range : chain;
			foreach (file; chain(bs.sourceFiles, bs.importFiles, bs.stringImportFiles))
				w.addFile(file);
		}

		auto cwd = Path(getcwd());
		auto runcwd = switchWorkDir(cwd, buildsettings.workingDirectory);
		scope(exit) chdir(cwd.toNativeString());

		auto cmd = runCmd(exe_file_path, cwd, runcwd, run_args);
		assert(!settings.runCallback);

		while (true)
		{
			logInfo("Running '%-(%s, %)'", cmd);
			auto pid = spawnProcess(cmd);
			w.wait(pid);
			auto res = tryWait(pid);
			if (res.terminated)
			{
				logInfo("Program exited with code %s.", res.status);
				return; // child process exited
			}
			logInfo("Stopping process...");
			import core.thread;
			// sleep a little, on some filesystems (vboxsf) modified notifications arrive before the change is written
			Thread.sleep(1.msecs);
			kill(pid);
			wait(pid);
			logInfo("Rebuilding target...");
			while (true)
			{
				w.readChanges(); // TODO: use list of changed files to optimize rebuild
				try {
					generateTargets(settings, targets);
					break;
				} catch (Exception e) {
					logWarn("Failed to build program: '%s'", e.msg);
					logDiagnostic("Full error: %s", e.toString().sanitize);
				}
				w.wait();
			}
		}
	}

	void cleanupTemporaries()
	{
		foreach_reverse (f; m_temporaryFiles) {
			try {
				if (f.endsWithSlash) rmdir(f.toNativeString());
				else remove(f.toNativeString());
			} catch (Exception e) {
				logWarn("Failed to remove temporary file '%s': %s", f.toNativeString(), e.msg);
				logDiagnostic("Full error: %s", e.toString().sanitize);
			}
		}
		m_temporaryFiles = null;
	}
}

version (linux)
	version = INOTIFY;
else version (FreeBSD)
	 version = KQUEUE;
else version (OSX)
	 version = KQUEUE;
else version(Windows) extern(Windows) {
	uint WaitForMultipleObjectsEx(uint, void**, bool, uint, bool);
	void* CreateFileW(const(wchar)*, uint, uint, void*, uint, uint, void*);
	bool ReadDirectoryChangesW(void*, void*, immutable(uint), bool, uint, uint*, void*, void*);
	bool CloseHandle(void*);
	void _CompletionRoutine(uint err, uint numbytes, void* overlapped) nothrow {}
	uint SleepEx(uint, bool);
} else 
	static assert(0, "Filewatcher support not yet implemented");

struct Watcher
{
	import core.stdc.errno;
	version (linux)
	import core.sys.linux.sys.inotify, core.sys.posix.fcntl : O_NONBLOCK;
	else version (FreeBSD)
		import core.sys.posix.fcntl, core.sys.freebsd.sys.event;
	else version (OSX)
		import core.sys.osx.sys.event;
	else version (Windows) {
		import std.utf : toUTF16z;
		import core.sys.windows.windows;
	}

	void addFile(string path)
	{
		version (INOTIFY) {
			static if (__VERSION__ < 2067)
				// value of IN_NONBLOCK in core.sys.linux.sys.inotify is incorrect
				enum IN_NONBLOCK = O_NONBLOCK;

			if (!eventfd)
				eventfd = inotify_init1(IN_NONBLOCK);

			if (inotify_add_watch(eventfd, path.toStringz(), IN_MODIFY) == -1)
			{
				if (errno == ENOSPC)
					logError("Not enough inotify watches, try to increase 'fs.inotify.max_user_watches'.");
				errnoEnforce(false);
			}
		} else version (KQUEUE) {
			if (!eventfd)
				eventfd = kqueue();

			version (OSX) {
				enum O_CLOEXEC = 0x1000000;
				enum oflags = O_EVTONLY | O_CLOEXEC;
			} else version (FreeBSD) {
				enum O_CLOEXEC = 0x00100000;
				enum oflags = O_RDONLY | O_CLOEXEC;
			}
			// TODO: leaking file descriptor
			auto fd = open(path.toStringz(), oflags);

			enum fflags = NOTE_WRITE;
			kevent_t event;
			EV_SET(&event, fd, EVFILT_VNODE, EV_ADD | EV_CLEAR, fflags, 0, null);
			errnoEnforce(kevent(eventfd, &event, 1, null, 0, null) != -1);
		} else version (Windows) {
			paths ~= path; 
		} else
			static assert(0, "no file watcher event system");
	}

	version(Windows)
	{
		// Recursively get more and more specific wrt first member of paths[]
		private Path getAncestor(Path[] paths, Path accum = Path([]), int cdepth = 0) {
			// vibe.d bug in opEquals?	accum should eventually == paths if paths.length = 1
			// but it never does.
			if(cdepth == 0) {
				accum = Path(paths[0][0]);
				return getAncestor(paths, accum, 1);
			} else {
				if(paths.all!(p => p.startsWith(accum)) && accum.length() < paths[0].length())// && accum != paths[0])
					return getAncestor(paths, accum ~ paths[0][cdepth], cdepth + 1);
				else
					return accum.parentPath();
			}
		}
		// Gets the most specific Ancestor Path a list of absolute paths:
		private string getAncestor(string[] paths) {
			auto ps = paths.map!(path => Path(path)).array; // lazy better?
			return to!string(getAncestor(ps)).replace("/", "\\");
		}
		// returns true if watched file has changed:
		bool processBuffer(void* buf) {
			struct FILE_NOTIFY_INFORMATION {
				uint NextEntryOffset;
				uint Action;
				uint FileNameLength;
				wchar[0] FileName; // variable length struct
			}
			logInfo("Processing buffer.");
			int nextOffset = 0;
			FILE_NOTIFY_INFORMATION* info;
			do {
				info = cast(FILE_NOTIFY_INFORMATION*)(buf + nextOffset);
				auto ws = (cast(wchar*)info.FileName)[0..info.FileNameLength/wchar.sizeof];
				string fname = to!string(to!wstring(ws)); // TODO: make this better?
				string fpath = joinPath(dir, fname).replace("/", "\\"); // why does vibe.d do this?
				if(paths.canFind(fpath) && info.Action == FILE_ACTION_MODIFIED) {
				   return true; 
				}
				// TODO: Check if this is actually a correct loop.
				nextOffset += info.NextEntryOffset; // NextEntryOffset = 0 when it's the last. 
				logInfo("Unwatched file event: " ~ fpath);
			} while (info.NextEntryOffset != 0);
			return false;
		}
		void createFileHandle() {
			if(hDir != INVALID_HANDLE_VALUE)
				return;
			dir = getAncestor(paths);
			logInfo("Determined to watch: " ~ dir);
			hDir = CreateFileW(toUTF16z(dir),
							   FILE_LIST_DIRECTORY, // required for reading changes
							   FILE_SHARE_READ | FILE_SHARE_WRITE, // No delete b/c
							   // otherwise user can delete the directory.
							   null, // security attr.
							   OPEN_EXISTING,
							   FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OVERLAPPED,
							   null);
			if(hDir == INVALID_HANDLE_VALUE)
				enforce(false, "Couldn't open directory.");
		}
		void wait(Pid pid)
		{
			createFileHandle();
			logInfo("Watching for changes in the files or process exit.");
			immutable buff_siz = 4096;
			void* buffer = cast(void*)(new ubyte[buff_siz]);
			uint bytesReturned = 0; // completely useless
			ubyte[12] ovlap;  // also useless
			uint result;
			do
			{
				if(!tryWait(pid).terminated) {
					auto initial = ReadDirectoryChangesW(hDir, buffer, buff_siz,
														 true, // watch subdirs
														 FILE_NOTIFY_CHANGE_LAST_WRITE,
														 &bytesReturned,
														 cast(void*)&ovlap, 
														 cast(void*)&_CompletionRoutine);
					enforce(initial, "winapi ReadDirectoryChangesW");
					void* hProc = pid.osHandle();
					result = WaitForMultipleObjectsEx(1, &hProc, true, INFINITE, true);
				} else 
					break;
			} while (result != WAIT_OBJECT_0 && !processBuffer(buffer));
		} 

		void wait()
		{
			createFileHandle();
			logInfo("Watching for changes in the files.");
			immutable buff_siz = 4096;
			void* buffer = cast(void*)(new byte[buff_siz]);
			uint bytesReturned = 0; // completely useless
			OVERLAPPED ovlap;  // also useless
			uint result;
			do {
				auto initial = ReadDirectoryChangesW(hDir, buffer, buff_siz,
													 true, // watch subdirs
													 FILE_NOTIFY_CHANGE_LAST_WRITE,
													 &bytesReturned,
													 &ovlap, cast(void*)&_CompletionRoutine);
				result = SleepEx(INFINITE, true);
			} while (!processBuffer(buffer));
		}

		void readChanges()
		{
			createFileHandle();
			// We already read the information in processBuffer.
		}

		~this()
		{
			if (hDir != INVALID_HANDLE_VALUE)
				CloseHandle(hDir);
		}

		string[] paths;
		string dir;
		void* hDir = INVALID_HANDLE_VALUE;
	}
	else  // Linux, BSD, OSX
	{
		void wait(Pid pid)
		{
			import core.sys.posix.signal, core.sys.posix.sys.select;

			// Block SIGCHLD
			sigset_t set;
			sigemptyset(&set);
			sigaddset(&set, SIGCHLD);
			sigprocmask(SIG_BLOCK, &set, null);

			// Add dummy handler SIGCHLD
			extern(C) void dummy_handler(int) {}
			sigaction_t sa;
			sa.sa_handler = &dummy_handler;
			sa.sa_flags = 0;
			sigemptyset(&sa.sa_mask);
			sigaction(SIGCHLD, &sa, null);

			if (!tryWait(pid).terminated)
			{
				fd_set rfds=void;
				FD_ZERO(&rfds);
				FD_SET(eventfd, &rfds);

				sigset_t emptyset;
				sigemptyset(&emptyset);
				// wait for inotify or SIGCHLD
				logInfo("Waiting for file changes or child exit.");
				auto res = pselect(eventfd+1, &rfds, null, null, null, &emptyset);
			}
			// Unblock SIGCHLD
			sigaddset(&set, SIGCHLD);
			sigprocmask(SIG_UNBLOCK, &set, null);

			// Remove SIGCHLD handler
			sigaction(SIGCHLD, cast(sigaction_t*)SIG_DFL, null);
		}
	
		void wait()
		{
			import core.sys.posix.sys.select;

			fd_set rfds=void;
			FD_ZERO(&rfds);
			FD_SET(eventfd, &rfds);
			logInfo("Waiting for file changes.");
			auto res = select(eventfd+1, &rfds, null, null, null);
		}

		void readChanges()
		{
			import core.stdc.errno, core.sys.posix.unistd;

			version (INOTIFY) {
				ubyte[1024] buf=void;
				while (true) {
					if (read(eventfd, buf.ptr, buf.length) != -1 || errno == EINTR)
						continue;
					else if (errno == EAGAIN)
						return;
					else
						errnoEnforce(false);
				}
			} else version (KQUEUE) {
				import core.sys.posix.time;
				timespec ts;
				kevent_t[8] buf=void;
				while (true) {
					auto res = kevent(eventfd, null, 0, buf.ptr, buf.length, &ts);
					if (res > 0)
						continue;
					else if (res == 0)
						return;
					else
						errnoEnforce(false);
				}
			}
		}

		~this()
		{
			import core.sys.posix.unistd;

			if (eventfd)
				close(eventfd);
		}

		int eventfd;
	}
}

private Path getMainSourceFile(in Package prj)
{
	foreach (f; ["source/app.d", "src/app.d", "source/"~prj.name~".d", "src/"~prj.name~".d"])
		if (existsFile(prj.path ~ f))
			return prj.path ~ f;
	return prj.path ~ "source/app.d";
}

unittest {
	version (Windows) {
		assert(isLinkerFile("test.obj"));
		assert(isLinkerFile("test.lib"));
		assert(isLinkerFile("test.res"));
		assert(!isLinkerFile("test.o"));
		assert(!isLinkerFile("test.d"));
	} else {
		assert(isLinkerFile("test.o"));
		assert(isLinkerFile("test.a"));
		assert(isLinkerFile("test.so"));
		assert(isLinkerFile("test.dylib"));
		assert(!isLinkerFile("test.obj"));
		assert(!isLinkerFile("test.d"));
	}
}
