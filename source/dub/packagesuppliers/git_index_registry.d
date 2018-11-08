module dub.packagesuppliers.git_index_registry;

import dub.packagesuppliers.packagesupplier;
import dub.packagesuppliers.registry : RegistryPackageSupplier;

/**
	Online registry based package supplier with local git index for dependency resolution.

	This package supplier connects to an online registry (e.g.
	$(LINK https://code.dlang.org/)) to search for available packages.
*/
class GitIndexRegistryPackageSupplier : RegistryPackageSupplier {
	import dub.internal.vibecompat.core.log;
	import dub.internal.vibecompat.data.json : parseJsonString;
	import dub.internal.vibecompat.inet.url : URL;
	import std.process : execute, ProcessConfig=Config;

	private {
		URL m_indexRepo;
		string m_repoPath;
		bool m_repoIsUpToDate;
	}

 	this(URL registry, URL indexRepo)
	{
		import std.uri : encodeComponent;

		super(registry);
		m_indexRepo = indexRepo;
		// TODO: use m_dirs.localRepository ~ /index
		m_repoPath = "/home/dawg/.dub/index/"~encodeComponent(indexRepo.toString);
	}

	override @property string description() { return super.description ~ " with index from "~m_indexRepo.toString(); }

	protected override Json getUncachedMetadata(string packageId)
	{
		import std.algorithm.iteration : map;
		import std.algorithm.searching : canFind;
		import std.array : array;
		import std.string : lineSplitter;

		if (!m_repoIsUpToDate)
			updateRepo();

		auto path = pkgPath(packageId);
		logDebug("Loading metadata %s from index git repository", path);
		// read file directly from git object database
		immutable git = execute(["git", "-C", m_repoPath, "show", "master:"~path]);
		if (git.status)
		{
			if (!git.output.canFind("does not exist"))
				logDiagnostic("Failed to load metadata %s from index git repository\n%s", git.output);
			return Json(null);
		}

		auto versions = git.output.lineSplitter
			.map!((ln) { auto j = parseJsonString(ln, path); j["name"] = packageId; return j; })
			.array;
		return Json(["versions": Json(versions)]);
	}

	private void updateRepo()
	{
		import std.conv : to;
		import std.file : exists;

		// TODO: use libgit2
		logInfo("Updating dub index");

		// TODO: detect corrupt repositories
		auto cmd = !m_repoPath.exists ?
			// clone a bare repo to not fiddle around with weird working dir states
			["git", "clone", "--quiet", "--bare", m_indexRepo.toString, m_repoPath] :
			// forcefully update local master ref (+ prefix) in case remote commits were squashed
			["git", "-C", m_repoPath, "fetch", "--quiet", "origin", "+master:master"];
		if (getLogLevel <= LogLevel.info)
			cmd ~= "--progress";
		immutable git = execute(cmd, null, ProcessConfig.stderrPassThrough);

		if (git.status)
		{
			logWarn("Failed to update index git repository, continuing with stale index.");
			logDiagnostic("  index git repository at %s", m_repoPath);
		}
		m_repoIsUpToDate = true;
	}

	// package path in repo
	private string pkgPath(string packageId)
	{
		assert(packageId.length);
		switch (packageId.length)
		{
		case 0: assert(0);
		case 1: return "1/"~packageId;
		case 2: return "2/"~packageId;
		case 3: return "3/"~packageId[0]~"/"~packageId;
		default: return packageId[0..2]~"/"~packageId[2..4]~"/"~packageId;
		}
	}
}
