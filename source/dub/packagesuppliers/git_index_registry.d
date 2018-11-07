module dub.packagesuppliers.git_index_registry;

import dub.packagesuppliers.packagesupplier;
import dub.packagesuppliers.registry : RegistryPackageSupplier;

/**
	Online registry based package supplier with local git index for dependency resolution.

	This package supplier connects to an online registry (e.g.
	$(LINK https://code.dlang.org/)) to search for available packages.
*/
class GitIndexRegistryPackageSupplier : RegistryPackageSupplier {
	import dub.internal.vibecompat.inet.url : URL;
	import dub.internal.vibecompat.data.json : parseJsonString;
	import std.file : exists;

	import dub.internal.vibecompat.core.log;

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
		import std.array : array;
		import std.path : buildPath;
		import std.stdio : File;

		if (!m_repoIsUpToDate)
			updateRepo();

		auto path = buildPath(m_repoPath, pkgPath(packageId));
		logDebug("Loading Metadata from %s %s", path, path.exists);
		if (!path.exists)
			return Json(null);

		auto versions = File(path).byLineCopy
			.map!((ln) { auto j = parseJsonString(ln, path); j["name"] = packageId; return j; })
			.array;
		return Json(["versions": Json(versions)]);
	}

	private void updateRepo()
	{
		import std.process : execute;

		// TODO: use libgit2
		logInfo("Updating dub index");
		immutable rc = m_repoPath.exists ? execute(["git", "-C", m_repoPath, "pull", "--quiet"]) :
			execute(["git", "clone", "--quiet", m_indexRepo.toString, m_repoPath]);
		if (rc.status)
		{
			logWarn("Failed to update dub index, continuing with stale index.");
			logDiagnostic("  dub index at %s", m_repoPath);
			logDiagnostic("%s", rc.output);
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
