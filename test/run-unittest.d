#!/usr/bin/env dub
/+dub.sdl:
	name: run_unittest
	targetName: run-unittest
	dependency "common" path="./common"
+/
module run_unittest;

import common;

int main(string[] args)
{
	import std.algorithm : among, filter;
	import std.file : chdir, dirEntries, DirEntry, exists, getcwd, readText, SpanMode;
	import std.format : format;
	import std.stdio : File, writeln, stdin, stdout;
	import std.path : absolutePath, buildNormalizedPath, baseName, buildPath, dirName;
	import std.process : environment, spawnProcess, wait;

	//** if [ -z ${DUB:-} ]; then
	//**     die $LINENO 'Variable $DUB must be defined to run the tests.'
	//** fi
	auto dub = environment.get("DUB", "");
	if (dub == "")
	{
		logError(`Environment variable "DUB" must be defined to run the tests.`);
		return 1;
	}

	//** if [ -z ${DC:-} ]; then
	//**     log '$DC not defined, assuming dmd...'
	//**     DC=dmd
	//** fi
	auto dc = environment.get("DC", "");
	if (dc == "")
	{
		log(`Environment variable "DC" not defined, assuming dmd...`);
		dc = "dmd";
	}

	// Clear log file
	{
		File(logFile, "w");
	}

	//** DC_BIN=$(basename "$DC")
	//** CURR_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
	//** FRONTEND="${FRONTEND:-}"
	const dc_bin = baseName(dc);
	const curr_dir = __FILE_FULL_PATH__.dirName();
	const frontend = environment.get("FRONTEND", "");

	chdir(curr_dir);

	// //** if [ "$#" -gt 0 ]; then FILTER=$1; else FILTER=".*"; fi
	// auto filter = (args.length > 1) ? args[1] : "*";

	version(Windows) string[] failing_build = [
		"1-dynLib-simple",
		"2-dynLib-with-staticLib-dep",
		"issue130-unicode-СНАЯАСТЕЯЅ",
		"issue1474",
		"git-dependency",
		"issue502-root-import",
	];
	version(Windows) string[] failing_run = [
		"3-copyFiles",
	];

	version (Posix)
	{
		//** for script in $(ls $CURR_DIR/*.sh); do
		//**     if [[ ! "$script" =~ $FILTER ]]; then continue; fi
		//**     if [ "$script" = "$(gnureadlink ${BASH_SOURCE[0]})" ] || [ "$(basename $script)" = "common.sh" ]; then continue; fi
		//**     if [ -e $script.min_frontend ] && [ ! -z "$FRONTEND" ] && [ ${FRONTEND} \< $(cat $script.min_frontend) ]; then continue; fi
		//**     log "Running $script..."
		//**     DUB=$DUB DC=$DC CURR_DIR="$CURR_DIR" $script || logError "Script failure."
		//** done
		foreach(DirEntry script; dirEntries(curr_dir, (args.length > 1) ? args[1] : "*.sh", SpanMode.shallow))
		{
			if (script.name.baseName.among("run-unittest.sh", "common.sh")) continue;
			const min_frontend = script.name ~ ".min_frontend";
			if (exists(min_frontend) && frontend.length && frontend < min_frontend.readText) continue;
			log("Running " ~ script.name.baseName ~ "...");
			// if (spawnProcess(script.name, ["DUB":dub, "DC":dc, "CURR_DIR":curr_dir]).wait)
			// 	logError("Script failure.");
		}
	}

	version(none) foreach (DirEntry script; dirEntries(curr_dir, (args.length > 1) ? args[1] : "*.script.d", SpanMode.shallow))
	{
		const min_frontend = script.name ~ ".min_frontend";
		if (frontend.length && exists(min_frontend) && frontend < min_frontend.readText) continue;
		log("Running " ~ script ~ "...");
		if (spawnProcess([dub, script.name], ["DUB":dub, "DC":dc, "CURR_DIR":curr_dir]).wait)
			logError("Script failure.");
		else
			log(script.name, " status: Ok");
	}

	// void[string] building, running, testing;

	// for pack in $(ls -d $CURR_DIR/*/); do
	foreach (DirEntry pack; dirEntries(curr_dir, (args.length > 1) ? args[1] : "*", SpanMode.shallow).filter!(a => a.isDir))
	{
		// skip directories that are not packages
		if (!buildPath(pack.name, "dub.sdl").exists && 
			!buildPath(pack.name, "dub.json").exists &&
			!buildPath(pack.name, "package.json").exists)
			continue;

		version(Windows) import std.algorithm : canFind;
		version(Windows) if (failing_build.canFind(pack.name.baseName)) continue;

		// skip packages that demands more recent frontend than the available one
		const min_frontend = buildPath(pack.name, ".min_frontend");
		if (frontend.length && exists(min_frontend) && frontend < min_frontend.readText) continue;

		// First we build the packages
		bool build;
		if (!buildPath(pack.name, ".no_build").exists && !buildPath(pack.name, ".no_build_" ~ dc_bin).exists)
		{
			build = true;
			auto logFile = File("log.log", "w"); // dummy
			if (buildPath(pack.name, ".fail_build").exists)
			{
				log("Building ", pack.name.baseName, ", expected failure...");
				// // $DUB build --force --root=$pack --compiler=$DC 2>/dev/null && logError "Error: Failure expected, but build passed."
				// if (!spawnProcess([dub, "build", "--force", "--root=" ~ pack.name, "--compiler=" ~ dc], stdin, logFile).wait)
				// 	logError("Error: Failure expected, but build passed.");
			}
			else
			{
				log("Building ", pack.name.baseName, "...");
				// // $DUB build --force --root=$pack --compiler=$DC || logError "Build failure."
				// if (spawnProcess([dub, "build", "--force", "--root=" ~ pack.name, "--compiler=" ~ dc], stdin, logFile).wait)
				// 	logError("Build failure");
			}
		}

		version(Windows) if (failing_run.canFind(pack.name.baseName)) continue;

		// We run the ones that are supposed to be run
		// if [ $build -eq 1 ] && [ ! -e $pack/.no_run ] && [ ! -e $pack/.no_run_$DC_BIN ]; then
		if (build && !buildPath(pack.name, ".no_run").exists && !buildPath(pack.name, ".no_run_" ~ dc_bin).exists)
		{
			log("Running ", pack.name.baseName, "...");
		// // 	# $DUB run --force --root=$pack --compiler=$DC || logError "Run failure."
		// 	if (spawnProcess([dub, "run", "--force", "--root=" ~ pack.name, "--compiler=" ~ dc]).wait)
		// 		logError("Run failure");
		}

		// Finally, the unittest part
		// if [ $build -eq 1 ] && [ ! -e $pack/.no_test ] && [ ! -e $pack/.no_test_$DC_BIN ]; then
		if (build && !buildPath(pack.name, ".no_test").exists && !buildPath(pack.name, ".no_test_" ~ dc_bin).exists)
		{
			log("Testing ", pack.name.baseName, "...");
		// // 	# $DUB test --force --root=$pack --compiler=$DC || logError "Test failure."
		// 	if (spawnProcess([dub, "test", "--force", "--root=" ~ pack.name, "--compiler=" ~ dc]).wait)
		// 		logError("Test failure");
		}
	}

	// echo
	// echo 'Testing summary:'
	// cat $(dirname "${BASH_SOURCE[0]}")/test.log
	import std.stdio;
	writeln("\nTesting summary2:");
	logFile.readText.writeln;

	return any_errors;
}
