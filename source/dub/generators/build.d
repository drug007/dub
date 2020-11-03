/**
	Generator for direct compiler builds.

	Copyright: © 2013-2013 rejectedsoftware e.K.
	License: Subject to the terms of the MIT license, as written in the included LICENSE.txt file.
	Authors: Sönke Ludwig
*/
module dub.generators.build;

import dub.compilers.compiler;
import dub.compilers.utils;
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

string getObjSuffix(const scope ref BuildPlatform platform)
{
	return platform.platform.canFind("windows") ? ".obj" : ".o";
}

string computeBuildName(string config, GeneratorSettings settings, const string[][] hashing...)
{
	import std.digest;
	import std.digest.md;

	MD5 hash;
	hash.start();
	void addHash(in string[] strings...) { foreach (s; strings) { hash.put(cast(ubyte[])s); hash.put(0); } hash.put(0); }
	foreach(strings; hashing)
		addHash(strings);
	auto hashstr = hash.finish().toHexString().idup;

	return format("%s-%s-%s-%s-%s_%s-%s", config, settings.buildType,
			settings.platform.platform.join("."),
			settings.platform.architecture.join("."),
			settings.platform.compiler, settings.platform.frontendVersion, hashstr);
}

class BuildGenerator : ProjectGenerator {
	private {
		PackageManager m_packageMan;
		NativePath[] m_temporaryFiles;
	}

	this(Project project)
	{
		super(project);
		m_packageMan = project.packageManager;
	}

	override void generateTargets(GeneratorSettings settings, in TargetInfo[string] targets)
	{
		scope (exit) cleanupTemporaries();

		void checkPkgRequirements(const(Package) pkg)
		{
			const tr = pkg.recipe.toolchainRequirements;
			tr.checkPlatform(settings.platform, pkg.name);
		}

		checkPkgRequirements(m_project.rootPackage);
		foreach (pkg; m_project.dependencies)
			checkPkgRequirements(pkg);

		auto root_ti = targets[m_project.rootPackage.name];

		enforce(!(settings.rdmd && root_ti.buildSettings.targetType == TargetType.none),
				"Building package with target type \"none\" with rdmd is not supported yet.");

		logInfo("Performing \"%s\" build using %s for %-(%s, %).",
			settings.buildType, settings.platform.compilerBinary, settings.platform.architecture);

		bool any_cached = false;

		NativePath[string] target_paths;

		bool[string] visited;
		void buildTargetRec(string target)
		{
			if (target in visited) return;
			visited[target] = true;

			auto ti = targets[target];

			foreach (dep; ti.dependencies)
				buildTargetRec(dep);

			NativePath[] additional_dep_files;
			auto bs = ti.buildSettings.dup;
			foreach (ldep; ti.linkDependencies) {
				if (bs.targetType != TargetType.staticLibrary && !(bs.options & BuildOption.syntaxOnly)) {
					bs.addSourceFiles(target_paths[ldep].toNativeString());
				} else {
					additional_dep_files ~= target_paths[ldep];
				}
			}
			NativePath tpath;
			if (bs.targetType != TargetType.none)
				if (buildTarget(settings, bs, ti.pack, ti.config, ti.packages, additional_dep_files, tpath))
					any_cached = true;
			target_paths[target] = tpath;
		}

		// build all targets
		if (settings.rdmd || root_ti.buildSettings.targetType == TargetType.staticLibrary) {
			// RDMD always builds everything at once and static libraries don't need their
			// dependencies to be built
			NativePath tpath;
			buildTarget(settings, root_ti.buildSettings.dup, m_project.rootPackage, root_ti.config, root_ti.packages, null, tpath);
		} else {
			buildTargetRec(m_project.rootPackage.name);

			if (any_cached) {
				logInfo("To force a rebuild of up-to-date targets, run again with --force.");
			}
		}
	}

	override void performPostGenerateActions(GeneratorSettings settings, in TargetInfo[string] targets)
	{
		// run the generated executable
		auto buildsettings = targets[m_project.rootPackage.name].buildSettings.dup;
		if (settings.run && !(buildsettings.options & BuildOption.syntaxOnly)) {
			NativePath exe_file_path;
			if (m_tempTargetExecutablePath.empty)
				exe_file_path = getTargetPath(buildsettings, settings);
			else
				exe_file_path = m_tempTargetExecutablePath ~ settings.compiler.getTargetFileName(buildsettings, settings.platform);
			runTarget(exe_file_path, buildsettings, settings.runArgs, settings);
		}
	}

	private bool buildTarget(GeneratorSettings settings, BuildSettings buildsettings, in Package pack, string config, in Package[] packages, in NativePath[] additional_dep_files, out NativePath target_path)
	{
		auto cwd = NativePath(getcwd());
		bool generate_binary = !(buildsettings.options & BuildOption.syntaxOnly);

		auto build_id = computeBuildID(config, buildsettings, settings);

		// make all paths relative to shrink the command line
		string makeRelative(string path) { return shrinkPath(NativePath(path), cwd); }
		foreach (ref f; buildsettings.sourceFiles) f = makeRelative(f);
		foreach (ref p; buildsettings.importPaths) p = makeRelative(p);
		foreach (ref p; buildsettings.stringImportPaths) p = makeRelative(p);

		// perform the actual build
		bool cached = false;
		if (settings.rdmd) performRDMDBuild(settings, buildsettings, pack, config, target_path);
		else if (settings.direct || !generate_binary) performDirectBuild(settings, buildsettings, pack, config, target_path);
		else cached = performCachedBuild(settings, buildsettings, pack, config, build_id, packages, additional_dep_files, target_path);

		// HACK: cleanup dummy doc files, we shouldn't specialize on buildType
		// here and the compiler shouldn't need dummy doc output.
		if (settings.buildType == "ddox") {
			if ("__dummy.html".exists)
				removeFile("__dummy.html");
			if ("__dummy_docs".exists)
				rmdirRecurse("__dummy_docs");
		}

		// run post-build commands
		if (!cached && buildsettings.postBuildCommands.length) {
			logInfo("Running post-build commands...");
			runBuildCommands(buildsettings.postBuildCommands, pack, m_project, settings, buildsettings);
		}

		return cached;
	}

	private bool performCachedBuild(GeneratorSettings settings, BuildSettings buildsettings, in Package pack, string config,
		string build_id, in Package[] packages, in NativePath[] additional_dep_files, out NativePath target_binary_path)
	{
		import std.typecons : scoped;

		auto cwd = NativePath(getcwd());

		NativePath target_path;
		if (settings.tempBuild) {
			string packageName = pack.basePackage is null ? pack.name : pack.basePackage.name;
			m_tempTargetExecutablePath = target_path = getTempDir() ~ format(".dub/build/%s-%s/%s/", packageName, pack.version_, build_id);
		}
		else target_path = pack.path ~ format(".dub/build/%s/", build_id);

		auto allfiles = listAllFiles(buildsettings, settings, pack, packages, additional_dep_files);
		auto buildCache = scoped!TimeDependentCache(target_path, buildsettings, settings, allfiles);
		auto hash_guard = HashGuard(target_path.toNativeString, settings.hash, allfiles);

		if (!settings.force && buildCache.isUpToDate) {
			logInfo("%s %s: target for configuration \"%s\" is up to date.", pack.name, pack.version_, config);
			logDiagnostic("Using existing build in %s.", target_path.toNativeString());
			target_binary_path = target_path ~ settings.compiler.getTargetFileName(buildsettings, settings.platform);
			if (!settings.tempBuild)
				copyTargetFile(target_path, buildsettings, settings);
			return true;
		}

		if (!isWritableDir(target_path, true)) {
			if (!settings.tempBuild)
				logInfo("Build directory %s is not writable. Falling back to direct build in the system's temp folder.", target_path.relativeTo(cwd).toNativeString());
			performDirectBuild(settings, buildsettings, pack, config, target_path);
			return false;
		}

		logInfo("%s %s: building configuration \"%s\"...", pack.name, pack.version_, config);

		if( buildsettings.preBuildCommands.length ){
			logInfo("Running pre-build commands...");
			runBuildCommands(buildsettings.preBuildCommands, pack, m_project, settings, buildsettings);
		}

		// override target path
		auto cbuildsettings = buildsettings;
		cbuildsettings.targetPath = shrinkPath(target_path, cwd);
		buildWithCompiler(settings, cbuildsettings);
		target_binary_path = getTargetPath(cbuildsettings, settings);

		if (!settings.tempBuild) {
			copyTargetFile(target_path, buildsettings, settings);
			hash_guard.saveFileHash;
		}

		return false;
	}

	private void performRDMDBuild(GeneratorSettings settings, ref BuildSettings buildsettings, in Package pack, string config, out NativePath target_path)
	{
		auto cwd = NativePath(getcwd());
		//Added check for existence of [AppNameInPackagejson].d
		//If exists, use that as the starting file.
		NativePath mainsrc;
		if (buildsettings.mainSourceFile.length) {
			mainsrc = NativePath(buildsettings.mainSourceFile);
			if (!mainsrc.absolute) mainsrc = pack.path ~ mainsrc;
		} else {
			mainsrc = getMainSourceFile(pack);
			logWarn(`Package has no "mainSourceFile" defined. Using best guess: %s`, mainsrc.relativeTo(pack.path).toNativeString());
		}

		// do not pass all source files to RDMD, only the main source file
		buildsettings.sourceFiles = buildsettings.sourceFiles.filter!(s => !s.endsWith(".d"))().array();
		settings.compiler.prepareBuildSettings(buildsettings, settings.platform, BuildSetting.commandLine);

		auto generate_binary = !buildsettings.dflags.canFind("-o-");

		// Create start script, which will be used by the calling bash/cmd script.
		// build "rdmd --force %DFLAGS% -I%~dp0..\source -Jviews -Isource @deps.txt %LIBS% source\app.d" ~ application arguments
		// or with "/" instead of "\"
		bool tmp_target = false;
		if (generate_binary) {
			if (settings.tempBuild || (settings.run && !isWritableDir(NativePath(buildsettings.targetPath), true))) {
				import std.random;
				auto rnd = to!string(uniform(uint.min, uint.max)) ~ "-";
				auto tmpdir = getTempDir()~".rdmd/source/";
				buildsettings.targetPath = tmpdir.toNativeString();
				buildsettings.targetName = rnd ~ buildsettings.targetName;
				m_temporaryFiles ~= tmpdir;
				tmp_target = true;
			}
			target_path = getTargetPath(buildsettings, settings);
			settings.compiler.setTarget(buildsettings, settings.platform);
		}

		logDiagnostic("Application output name is '%s'", settings.compiler.getTargetFileName(buildsettings, settings.platform));

		string[] flags = ["--build-only", "--compiler="~settings.platform.compilerBinary];
		if (settings.force) flags ~= "--force";
		flags ~= buildsettings.dflags;
		flags ~= mainsrc.relativeTo(cwd).toNativeString();

		if (buildsettings.preBuildCommands.length){
			logInfo("Running pre-build commands...");
			runCommands(buildsettings.preBuildCommands);
		}

		logInfo("%s %s: building configuration \"%s\"...", pack.name, pack.version_, config);

		logInfo("Running rdmd...");
		logDiagnostic("rdmd %s", join(flags, " "));
		auto rdmd_pid = spawnProcess("rdmd" ~ flags);
		auto result = rdmd_pid.wait();
		enforce(result == 0, "Build command failed with exit code "~to!string(result));

		if (tmp_target) {
			m_temporaryFiles ~= target_path;
			foreach (f; buildsettings.copyFiles)
				m_temporaryFiles ~= NativePath(buildsettings.targetPath).parentPath ~ NativePath(f).head;
		}
	}

	private void performDirectBuild(GeneratorSettings settings, ref BuildSettings buildsettings, in Package pack, string config, out NativePath target_path)
	{
		auto cwd = NativePath(getcwd());
		auto generate_binary = !(buildsettings.options & BuildOption.syntaxOnly);

		// make file paths relative to shrink the command line
		foreach (ref f; buildsettings.sourceFiles) {
			auto fp = NativePath(f);
			if( fp.absolute ) fp = fp.relativeTo(cwd);
			f = fp.toNativeString();
		}

		logInfo("%s %s: building configuration \"%s\"...", pack.name, pack.version_, config);

		// make all target/import paths relative
		string makeRelative(string path) {
			auto p = NativePath(path);
			// storing in a separate temprary to work around #601
			auto prel = p.absolute ? p.relativeTo(cwd) : p;
			return prel.toNativeString();
		}
		buildsettings.targetPath = makeRelative(buildsettings.targetPath);
		foreach (ref p; buildsettings.importPaths) p = makeRelative(p);
		foreach (ref p; buildsettings.stringImportPaths) p = makeRelative(p);

		bool is_temp_target = false;
		if (generate_binary) {
			if (settings.tempBuild || (settings.run && !isWritableDir(NativePath(buildsettings.targetPath), true))) {
				import std.random;
				auto rnd = to!string(uniform(uint.min, uint.max));
				auto tmppath = getTempDir()~("dub/"~rnd~"/");
				buildsettings.targetPath = tmppath.toNativeString();
				m_temporaryFiles ~= tmppath;
				is_temp_target = true;
			}
			target_path = getTargetPath(buildsettings, settings);
		}

		if( buildsettings.preBuildCommands.length ){
			logInfo("Running pre-build commands...");
			runBuildCommands(buildsettings.preBuildCommands, pack, m_project, settings, buildsettings);
		}

		buildWithCompiler(settings, buildsettings);

		if (is_temp_target) {
			m_temporaryFiles ~= target_path;
			foreach (f; buildsettings.copyFiles)
				m_temporaryFiles ~= NativePath(buildsettings.targetPath).parentPath ~ NativePath(f).head;
		}
	}

	private string computeBuildID(string config, in BuildSettings buildsettings, GeneratorSettings settings)
	{
		const(string[])[] hashing = [
			buildsettings.versions,
			buildsettings.debugVersions,
			buildsettings.dflags,
			buildsettings.lflags,
			buildsettings.stringImportPaths,
			buildsettings.importPaths,
			settings.platform.architecture,
			[
				(cast(uint)buildsettings.options).to!string,
				settings.platform.compilerBinary,
				settings.platform.compiler,
				settings.platform.frontendVersion.to!string,
			],
		];

		return computeBuildName(config, settings, hashing);
	}

	private void copyTargetFile(NativePath build_path, BuildSettings buildsettings, GeneratorSettings settings)
	{
		auto filename = settings.compiler.getTargetFileName(buildsettings, settings.platform);
		auto src = build_path ~ filename;
		logDiagnostic("Copying target from %s to %s", src.toNativeString(), buildsettings.targetPath);
		if (!existsFile(NativePath(buildsettings.targetPath)))
			mkdirRecurse(buildsettings.targetPath);
		hardLinkFile(src, NativePath(buildsettings.targetPath) ~ filename, true);
	}

	// list all files this project is dependent on
	private auto listAllFiles(in BuildSettings buildsettings, in GeneratorSettings settings, in Package main_pack, in Package[] packages, in NativePath[] additional_dep_files)
	{
		auto allfiles = appender!(string[]);
		allfiles ~= buildsettings.sourceFiles;
		allfiles ~= buildsettings.importFiles;
		allfiles ~= buildsettings.stringImportFiles;
		allfiles ~= buildsettings.extraDependencyFiles;
		// TODO: add library files
		foreach (p; packages)
			allfiles ~= (p.recipePath != NativePath.init ? p : p.basePackage).recipePath.toNativeString();
		foreach (f; additional_dep_files) allfiles ~= f.toNativeString();
		bool checkSelectedVersions = !settings.single;
		if (checkSelectedVersions && main_pack is m_project.rootPackage && m_project.rootPackage.getAllDependencies().length > 0)
			allfiles ~= (main_pack.path ~ SelectedVersions.defaultFile).toNativeString();

		return allfiles.data;
	}

	/// Output an unique name to represent the source file.
	/// Calls with path that resolve to the same file on the filesystem will return the same,
	/// unless they include different symbolic links (which are not resolved).

	static string pathToObjName(const scope ref BuildPlatform platform, string path)
	{
		import std.digest.crc : crc32Of;
		import std.path : buildNormalizedPath, dirSeparator, relativePath, stripDrive;
		if (path.endsWith(".d")) path = path[0 .. $-2];
		auto ret = buildNormalizedPath(getcwd(), path).replace(dirSeparator, ".");
		auto idx = ret.lastIndexOf('.');
		const objSuffix = getObjSuffix(platform);
		return idx < 0 ? ret ~ objSuffix : format("%s_%(%02x%)%s", ret[idx+1 .. $], crc32Of(ret[0 .. idx]), objSuffix);
	}

	/// Compile a single source file (srcFile), and write the object to objName.
	static string compileUnit(string srcFile, string objName, BuildSettings bs, GeneratorSettings gs) {
		NativePath tempobj = NativePath(bs.targetPath)~objName;
		string objPath = tempobj.toNativeString();
		bs.libs = null;
		bs.lflags = null;
		bs.sourceFiles = [ srcFile ];
		bs.targetType = TargetType.object;
		gs.compiler.prepareBuildSettings(bs, gs.platform, BuildSetting.commandLine);
		gs.compiler.setTarget(bs, gs.platform, objPath);
		gs.compiler.invoke(bs, gs.platform, gs.compileCallback);
		return objPath;
	}

	private void buildWithCompiler(GeneratorSettings settings, BuildSettings buildsettings)
	{
		auto generate_binary = !(buildsettings.options & BuildOption.syntaxOnly);
		auto is_static_library = buildsettings.targetType == TargetType.staticLibrary || buildsettings.targetType == TargetType.library;

		scope (failure) {
			logDiagnostic("FAIL %s %s %s" , buildsettings.targetPath, buildsettings.targetName, buildsettings.targetType);
			auto tpath = getTargetPath(buildsettings, settings);
			if (generate_binary && existsFile(tpath))
				removeFile(tpath);
		}
		if (settings.buildMode == BuildMode.singleFile && generate_binary) {
			import std.parallelism, std.range : walkLength;

			auto lbuildsettings = buildsettings;
			auto srcs = buildsettings.sourceFiles.filter!(f => !isLinkerFile(settings.platform, f));
			auto objs = new string[](srcs.walkLength);

			void compileSource(size_t i, string src) {
				logInfo("Compiling %s...", src);
				const objPath = pathToObjName(settings.platform, src);
				objs[i] = compileUnit(src, objPath, buildsettings, settings);
			}

			if (settings.parallelBuild) {
				foreach (i, src; srcs.parallel(1)) compileSource(i, src);
			} else {
				foreach (i, src; srcs.array) compileSource(i, src);
			}

			logInfo("Linking...");
			lbuildsettings.sourceFiles = is_static_library ? [] : lbuildsettings.sourceFiles.filter!(f => isLinkerFile(settings.platform, f)).array;
			settings.compiler.setTarget(lbuildsettings, settings.platform);
			settings.compiler.prepareBuildSettings(lbuildsettings, settings.platform, BuildSetting.commandLineSeparate|BuildSetting.sourceFiles);
			settings.compiler.invokeLinker(lbuildsettings, settings.platform, objs, settings.linkCallback);

		// NOTE: separate compile/link is not yet enabled for GDC.
		} else if (generate_binary && (settings.buildMode == BuildMode.allAtOnce || settings.compiler.name == "gdc" || is_static_library)) {
			// don't include symbols of dependencies (will be included by the top level target)
			if (is_static_library) buildsettings.sourceFiles = buildsettings.sourceFiles.filter!(f => !isLinkerFile(settings.platform, f)).array;

			// setup for command line
			settings.compiler.setTarget(buildsettings, settings.platform);
			settings.compiler.prepareBuildSettings(buildsettings, settings.platform, BuildSetting.commandLine);

			// invoke the compiler
			settings.compiler.invoke(buildsettings, settings.platform, settings.compileCallback);
		} else {
			// determine path for the temporary object file
			string tempobjname = buildsettings.targetName ~ getObjSuffix(settings.platform);
			NativePath tempobj = NativePath(buildsettings.targetPath) ~ tempobjname;

			// setup linker command line
			auto lbuildsettings = buildsettings;
			lbuildsettings.sourceFiles = lbuildsettings.sourceFiles.filter!(f => isLinkerFile(settings.platform, f)).array;
			if (generate_binary) settings.compiler.setTarget(lbuildsettings, settings.platform);
			settings.compiler.prepareBuildSettings(lbuildsettings, settings.platform, BuildSetting.commandLineSeparate|BuildSetting.sourceFiles);

			// setup compiler command line
			buildsettings.libs = null;
			buildsettings.lflags = null;
			if (generate_binary) buildsettings.addDFlags("-c", "-of"~tempobj.toNativeString());
			buildsettings.sourceFiles = buildsettings.sourceFiles.filter!(f => !isLinkerFile(settings.platform, f)).array;

			settings.compiler.prepareBuildSettings(buildsettings, settings.platform, BuildSetting.commandLine);

			settings.compiler.invoke(buildsettings, settings.platform, settings.compileCallback);

			if (generate_binary) {
				logInfo("Linking...");
				settings.compiler.invokeLinker(lbuildsettings, settings.platform, [tempobj.toNativeString()], settings.linkCallback);
			}
		}
	}

	private void runTarget(NativePath exe_file_path, in BuildSettings buildsettings, string[] run_args, GeneratorSettings settings)
	{
		if (buildsettings.targetType == TargetType.executable) {
			auto cwd = NativePath(getcwd());
			auto runcwd = cwd;
			if (buildsettings.workingDirectory.length) {
				runcwd = NativePath(buildsettings.workingDirectory);
				if (!runcwd.absolute) runcwd = cwd ~ runcwd;
				logDiagnostic("Switching to %s", runcwd.toNativeString());
				chdir(runcwd.toNativeString());
			}
			scope(exit) chdir(cwd.toNativeString());
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
			runPreRunCommands(m_project.rootPackage, m_project, settings, buildsettings);
			logInfo("Running %s %s", exe_path_string, run_args.join(" "));
			if (settings.runCallback) {
				auto res = execute(exe_path_string ~ run_args);
				settings.runCallback(res.status, res.output);
				settings.targetExitStatus = res.status;
				runPostRunCommands(m_project.rootPackage, m_project, settings, buildsettings);
			} else {
				auto prg_pid = spawnProcess(exe_path_string ~ run_args);
				auto result = prg_pid.wait();
				settings.targetExitStatus = result;
				runPostRunCommands(m_project.rootPackage, m_project, settings, buildsettings);
				enforce(result == 0, "Program exited with code "~to!string(result));
			}
		} else
			enforce(false, "Target is a library. Skipping execution.");
	}

	private void runPreRunCommands(in Package pack, in Project proj, in GeneratorSettings settings,
		in BuildSettings buildsettings)
	{
		if (buildsettings.preRunCommands.length) {
			logInfo("Running pre-run commands...");
			runBuildCommands(buildsettings.preRunCommands, pack, proj, settings, buildsettings);
		}
	}

	private void runPostRunCommands(in Package pack, in Project proj, in GeneratorSettings settings,
		in BuildSettings buildsettings)
	{
		if (buildsettings.postRunCommands.length) {
			logInfo("Running post-run commands...");
			runBuildCommands(buildsettings.postRunCommands, pack, proj, settings, buildsettings);
		}
	}

	private void cleanupTemporaries()
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

/// return true if the conversion was successful
private bool fromHexString(string hexBuffer, ubyte[] byteBuffer) {
	enforce(byteBuffer.length == hexBuffer.length / 2, "fromHexString buffers size mismatch");
	int i;
	bool low;
	foreach (ch; hexBuffer)
	{
		int v = cast(int) ch;
		// [0..9]
		if (v >= 48 && v <= 57)
			v -= 48;
		// [A..F]
		else if (v >= 65 && v <= 70)
			v -= 55;
		// [a..f]
		else if (v>= 97 && v <= 102)
			v -= 87;
		else
			return false;

		if (low)
			byteBuffer[i++] |= v & 15;
		else
			byteBuffer[i] = (v & 15) << 4;

		low = !low;
	}

	assert(i == byteBuffer.length);

	return true;
}

interface BuildCache {
	/// recalculate cache id on given files
	void rebuildCache();
	/// returns true if all file are up to date
	bool isUpToDate();
	/// save current state of the cache (should be called after successful rebuilding)
	void saveCache();
}

class TimeDependentCache : BuildCache {
	private {
		NativePath _targetfile;
		const(string[]) _allfiles;
	}

	/// create an instance of the build cache
	/// target_path
	/// buildsettings
	/// settings
	/// allfiles is the list of files in native form
	this(NativePath target_path, BuildSettings buildsettings, GeneratorSettings settings, in string[] allfiles)
	{
		_targetfile = target_path ~ settings.compiler.getTargetFileName(buildsettings, settings.platform);
		_allfiles = allfiles;
	}

	/// ditto
	void rebuildCache() {
		// nothing to do
	}

	/// ditto
	bool isUpToDate() {
		import std.datetime : Clock;

		if (!existsFile(_targetfile)) {
			logDiagnostic("Target '%s' doesn't exist, need rebuild.", _targetfile.toNativeString());
			return false;
		}

		const targettime = getFileInfo(_targetfile).timeModified;
		foreach (file; _allfiles) {
			if (!existsFile(file)) {
				logDiagnostic("File %s doesn't exist, triggering rebuild.", file);
				return false;
			}
			const ftime = getFileInfo(file).timeModified;
			if (ftime > Clock.currTime)
				logWarn("File '%s' was modified in the future. Please re-save.", file);
			if (ftime > targettime) {
				logDiagnostic("File '%s' modified, need rebuild.", file);
				return false;
			}
		}

		return true;
	}

	/// ditto
	void saveCache() {
		// nothing to do
	}
}

private struct HashGuard
{
	import std.stdio : File;
	import std.digest : toHexString;

	string target_path;
	string[] filenames;
	HashKind kind;
	ubyte[32] buffer;

	this(string target_path, HashKind kind, string[] allfiles)
	{
		this.target_path = target_path;
		this.kind = kind;
		this.filenames = allfiles;
	}

	@disable this();

	void calculateHash(string filename, ubyte[] sha) {
		try
		{
			import std.digest.sha : SHA1Digest, SHA256Digest;
			import std.digest : Digest;
			import std.exception : ErrnoException;
			import std.algorithm : each;
			import std.conv : emplace;

			enum ChunkSize = 4096;
			enum BufSize = max(
				__traits(classInstanceSize, SHA1Digest),
				__traits(classInstanceSize, SHA256Digest),
			);
			ubyte[BufSize] buffer = void;

			Digest hash;

			final switch(kind) {
				case HashKind.none:
					assert(0);
				case HashKind.sha1:
					hash = emplace!SHA1Digest(buffer);
				break;
				case HashKind.sha256:
					hash = emplace!SHA256Digest(buffer);
				break;
			}

			File(filename, "r").byChunk(ChunkSize).each!(a=>hash.put(a));
			enforce(sha.length == hash.length);
			hash.finish(sha);
			destroy(hash);
		}
		catch (ErrnoException ex)
		{
			import core.stdc.errno : EPERM, EACCES, ENOENT;

			switch(ex.errno)
			{
				case EPERM:
				case EACCES:
					logError("%s: permission denied", filename);
					break;

				case ENOENT:
					logError("%s: file does not exist", filename);
					break;

				default:
					logError("%s: reading failed", filename);
					break;

			}
		}
	}

	auto hashBuffer() {
		final switch(kind) {
			case HashKind.none:
				assert(0);
			case HashKind.sha1:
				return buffer[0..20];
			case HashKind.sha256:
				return buffer[0..32];
		}
	}

	auto hashFilename() const {
		import std.path : buildPath;
		final switch(kind) {
			case HashKind.none:
				assert(0);
			case HashKind.sha1:
				return buildPath(target_path, "filehash.sha1");
			case HashKind.sha256:
				return buildPath(target_path, "filehash.sha256");
		}
	}

	auto checkFiles() {
		ubyte[][string] hashes;
		if (existsFile(hashFilename))
		{
			import std.string : strip;
			foreach(file; slurp!(string, "str_hash", string, "name")(hashFilename, "%s %s"))
			{
				if (!fromHexString(file.str_hash, hashBuffer))
				{
					logError("Failed to get hash of source files, triggering rebuild");
					// TODO rename the file to prevent cycling failure
					return false;
				}
				hashes[file.name.strip] = hashBuffer.dup;
			}
		}

		foreach (file; filenames) {
			if (!existsFile(file)) {
				logDiagnostic("File %s doesn't exist, triggering rebuild.", file);
				return false;
			}
			calculateHash(file, hashBuffer);
			if (file !in hashes || hashBuffer != hashes[file]) {
				logWarn("File `%s`: hash was changed, triggering rebuild.", file);
				return false;
			}
		}

		return true;
	}

	auto saveFileHash() {
		ubyte[][string] hashes;

		foreach (file; filenames) {
			if (!existsFile(file)) {
				logError("File %s doesn't exist.", file);
				continue;
			}
			calculateHash(file, hashBuffer);
			hashes[file] = hashBuffer.dup;
		}

		auto file = File(hashFilename, "w");
		foreach(pair; hashes.byKeyValue)
			file.writefln("%s %s", pair.value.toHexString!(LetterCase.lower), pair.key);

		return true;
	}
}

private NativePath getMainSourceFile(in Package prj)
{
	foreach (f; ["source/app.d", "src/app.d", "source/"~prj.name~".d", "src/"~prj.name~".d"])
		if (existsFile(prj.path ~ f))
			return prj.path ~ f;
	return prj.path ~ "source/app.d";
}

private NativePath getTargetPath(const scope ref BuildSettings bs, const scope ref GeneratorSettings settings)
{
	return NativePath(bs.targetPath) ~ settings.compiler.getTargetFileName(bs, settings.platform);
}

private string shrinkPath(NativePath path, NativePath base)
{
	auto orig = path.toNativeString();
	if (!path.absolute) return orig;
	auto ret = path.relativeTo(base).toNativeString();
	return ret.length < orig.length ? ret : orig;
}

unittest {
	assert(shrinkPath(NativePath("/foo/bar/baz"), NativePath("/foo")) == NativePath("bar/baz").toNativeString());
	assert(shrinkPath(NativePath("/foo/bar/baz"), NativePath("/foo/baz")) == NativePath("../bar/baz").toNativeString());
	assert(shrinkPath(NativePath("/foo/bar/baz"), NativePath("/bar/")) == NativePath("/foo/bar/baz").toNativeString());
	assert(shrinkPath(NativePath("/foo/bar/baz"), NativePath("/bar/baz")) == NativePath("/foo/bar/baz").toNativeString());
}

unittest { // issue #1235 - pass no library files to compiler command line when building a static lib
	import dub.internal.vibecompat.data.json : parseJsonString;
	import dub.compilers.gdc : GDCCompiler;
	import dub.platform : determinePlatform;

	version (Windows) auto libfile = "bar.lib";
	else auto libfile = "bar.a";

	auto desc = parseJsonString(`{"name": "test", "targetType": "library", "sourceFiles": ["foo.d", "`~libfile~`"]}`);
	auto pack = new Package(desc, NativePath("/tmp/fooproject"));
	auto pman = new PackageManager(pack.path, NativePath("/tmp/foo/"), NativePath("/tmp/foo/"), false);
	auto prj = new Project(pman, pack);

	final static class TestCompiler : GDCCompiler {
		override void invoke(in BuildSettings settings, in BuildPlatform platform, void delegate(int, string) output_callback) {
			assert(!settings.dflags[].any!(f => f.canFind("bar")));
		}
		override void invokeLinker(in BuildSettings settings, in BuildPlatform platform, string[] objects, void delegate(int, string) output_callback) {
			assert(false);
		}
	}

	GeneratorSettings settings;
	settings.platform = BuildPlatform(determinePlatform(), ["x86"], "gdc", "test", 2075);
	settings.compiler = new TestCompiler;
	settings.config = "library";
	settings.buildType = "debug";
	settings.tempBuild = true;

	auto gen = new BuildGenerator(prj);
	gen.generate(settings);
}
