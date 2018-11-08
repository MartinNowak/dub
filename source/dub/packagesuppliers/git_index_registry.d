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
	import std.typecons : Nullable;
	import git;

	private {
		string m_remoteRepo;
		string m_repoPath;
		GitRepo m_repo;
		bool m_isUpToDate;
	}

 	this(URL registry, URL remoteRepo)
	{
		import std.uri : encodeComponent;

		super(registry);
		m_remoteRepo = remoteRepo.toString;
		// TODO: use m_dirs.localRepository ~ /index
		m_repoPath = "/home/dawg/.dub/index/"~encodeComponent(m_remoteRepo);
	}

	override @property string description() { return super.description ~ " with index from "~m_remoteRepo; }

	protected override Json getUncachedMetadata(string packageId)
	{
		import std.algorithm.iteration : map;
		import std.array : array;
		import std.string : lineSplitter;

		if (!m_isUpToDate)
			updateRepo();

		auto path = pkgPath(packageId);
		logDebug("Loading metadata %s from index git repository", path);

		GitCommit commit;
		try
			commit = m_repo.lookupCommit(m_repo.head.target);
		catch (GitException e)
			corruptRepo(e, "HEAD points to an invalid commit");

		GitTree tree;
		try
			tree = commit.tree;
		catch (GitException e)
			corruptRepo(e, "Commit %s points to an invalid tree", commit.id.toHex);

		// TODO: check underlying GIT_ENOTFOUND return code instead of relying on exception
		GitTreeEntry entry;
		try
			entry = tree.getEntryByPath(path);
		catch (GitException e)
			return Json(null);

		if (entry.type != GitType.blob)
			corruptRepo(null, "Entry at path %s is a %s instead of a blob", path, entry.type);


		GitBlob blob;
		try
			blob = m_repo.lookupBlob(entry.id);
		catch (GitException e)
			corruptRepo(e, "Failed to find blob %s for path %s", entry.id.toHex, path);

		// We got a checksum correct blob from git, so assume we didn't
		// write invalid UTF-8 or broken json data to the repo.
		const(char)[] content;
		try
			content = (cast(const char[])blob.rawContent);
		catch (GitException e)
			corruptRepo(e, "Failed to read blob %s", entry.id.toHex);

		auto versions = content.lineSplitter
			.map!((ln) { auto j = parseJsonString(ln.idup, path); j["name"] = packageId; return j; })
			.array;
		return Json(["versions": Json(versions)]);
	}

	private void printProgress(in ref GitTransferProgress stats)
	{
		import std.stdio : stderr;

		stderr.writef!" %2.0f %% (%6s/%6s commits)\r"(100.0 * stats.receivedObjects / stats.totalObjects,
			stats.receivedObjects, stats.totalObjects);
		// stderr.flush();
	}

	private void updateRepo()
	{
		import std.conv : to;
		import std.exception : collectException;
		import std.file : exists, rmdirRecurse;
		import std.stdio : stderr;

		logInfo("Updating dub index");
		m_isUpToDate = true; // don't retry updating ad infinitum on failure

		if (m_repoPath.exists)
		{
			// check that the repo has a valid HEAD
			if (!collectException!GitException(m_repo = m_repoPath.openBareRepository) &&
				!collectException!GitException(m_repo.head))
			{
				auto remote = m_repo.createRemoteInMemory("+refs/heads/master:refs/heads/master", m_remoteRepo);
				try
				{
					remote.connect(GitDirection.fetch);
					remote.download(&printProgress);
					remote.updateTips((refname, ref a, ref b) scope =>
						logDiagnostic("  updated %s from %s to %s", refname, a.toHex, b.toHex));
				}
				catch (GitException e)
				{
					// TODO: distinguish between temporary network failure and corrupt repo
					logWarn("Failed to update index git repository, continuing with stale index.\n  %s", e.msg);
					logDiagnostic("  index git repository at %s", m_repoPath);
				}
				return;
			}
			// or try to remove and reclone otherwise
			rmdirRecurse(m_repoPath);
		}

		GitCloneOptions cloneOpts;
		cloneOpts.cloneBare = true;
		if (getLogLevel <= LogLevel.info)
		{} // cloneOpts.fetchProgessCallback = &printProgress; // targetLibGitVersion == VersionInfo(0, 19, 0)
		try
			m_repo = cloneRepo(m_remoteRepo, m_repoPath, cloneOpts);
		catch (GitException e)
		{
			logError("Failed to clone index git repository (%s)", e.msg);
			logDiagnostic("  index git repository at %s", m_repoPath);
			throw e;
		}
		if (getLogLevel <= LogLevel.info)
		{} // stderr.writeln();

		if (auto e = collectException!GitException(m_repo.head))
		{
			logError("Cloned index git repository at %s is invalid, consider removing it.\n%s", m_repoPath, e.msg);
			throw e;
		}
	}

    private void corruptRepo(Args...)(Throwable nextInChain, string fmt, Args args)
	{
		logError("Presumably your index git repository at '%s' is corrupt, try removing it.", m_repoPath);
		logError("  "~fmt, args);
		if (nextInChain !is null)
			logDebug("  %s", nextInChain.msg);
		throw new CorruptRepo(m_repoPath, nextInChain);
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

class CorruptRepo : Exception
{
	this(string repoPath, Throwable nextInChain=null, string file = __FILE__, size_t line = __LINE__)
	{
		super("Corrupt index git repository at "~repoPath, nextInChain, file, line);
	}
}
