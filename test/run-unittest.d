#!/usr/bin/env dub
/+dub.sdl:
	name: run_unittest
	targetName: run-unittest
+/
module run_unittest;

import std.algorithm : endsWith;
import std.file : chdir, DirEntry, dirEntries, exists, getcwd, SpanMode, readText;
import std.format : format;
import std.process : environment;
import std.path : baseName, buildPath, pathSplitter;
import std.range : walkLength;
import std.stdio : File, stderr, writeln, writefln;

enum logFile = "test.log";

// $DUB $DUB_COMMAND --force --root=$CURR_DIR --compiler=$DC
// $DUB_COMMAND {build|run|test}
version (Windows) enum shellCommand = "%2$s %1$s --force --root=%3$s --compiler=%4$s";
else              enum shellCommand = "%2$s %1$s --force --root=%3$s --compiler=%4$s 2>/dev/null";

/// has true if some test fails
bool any_errors;

/// prints (non error) message to standard output and log file
void log(Args...)(Args args)
	if (Args.length)
{
	version(Windows) const str = format("[INFO] " ~ args[0], args[1..$]);
	else const str = format("\033[0;31m[INFO] " ~ args[0] ~ "\033[0m", args[1..$]).format(args[1..$]);
	writeln(str);
	File(logFile, "a").writeln(str);
}

/// prints error message to standard error stream and log file
/// and set any_errors var to true value to indicate that some
/// test fails
void logError(Args...)(Args args)
{
	version(Windows) const str = format("[ERROR] " ~ args[0], args[1..$]);
	else const str = format("\033[0;31m[ERROR] " ~ args[0] ~ "\033[0m", args[1..$]).format(args[1..$]);
	stderr.writeln(str);
	File(logFile, "a").writeln(str);
	any_errors = true;
}

enum DubCommand { build = "build", run = "run", test = "test", }

auto execute(DubCommand cmd, string dub, string pack, string dc)
{
	import std.process : executeShell;
	import std.range : take;

	const r = executeShell(shellCommand.format(cmd, dub, pack, dc));
	// output can be long
	enum maxSize = 1024;
	writeln(r.output.take(maxSize));
	if (r.output.length > maxSize)
		writefln("...\nOnly first %s symbols output\n", maxSize);
	return r;
}

int main(string[] args)
{
	auto dub = environment.get("DUB", "");
	if (dub == "")
	{
		logError("Environment variable `DUB` must be defined to run the tests.");
		return 1;
	}

	auto dc = environment.get("DC", "");
	if (dc == "")
	{
		log("Environment variable `DC` not defined, assuming dmd...");
		dc = "dmd";
	}

	// Clear log file
	{
		File(logFile, "w");
	}

	auto dc_bin = baseName(dc);
	auto curr_dir = getcwd;
	auto frontend = environment.get("FRONTEND", "");

	auto filter = (args.length > 1) ? args[1] : "*";

// # for script in $(ls $CURR_DIR/*.sh); do
// #     if [[ ! "$script" =~ $FILTER ]]; then continue; fi
// #     if [ "$script" = "$(gnureadlink ${BASH_SOURCE[0]})" ] || [ "$(basename $script)" = "common.sh" ]; then continue; fi
// #     if [ -e $script.min_frontend ] && [ ! -z "$FRONTEND" ] && [ ${FRONTEND} \< $(cat $script.min_frontend) ]; then continue; fi
// #     log "Running $script..."
// #     DUB=$DUB DC=$DC CURR_DIR="$CURR_DIR" $script || logError "Script failure."
// # done

	const root_path_size = getcwd.pathSplitter.walkLength;

	foreach(DirEntry de; dirEntries(curr_dir, filter, SpanMode.breadth))
	{
		// (process only dirs (regular packages) and D files (single file packages))
		// skip non D files 
		if (de.isFile && !de.name.endsWith(".d"))
			continue;
		// the file/dir shall be nested to the current dir (1 level nesting)
		if (de.name.pathSplitter.walkLength != root_path_size + 1)
			continue;
		const pack = de.name;
		// check for minimal frontend version
		{
			auto filepath = buildPath(pack, ".min_frontend");
			if (filepath.exists)
			{
				auto min_frontend = readText(filepath);
				if (frontend.length == 1 || frontend < min_frontend)
					continue;
			}
		}

		bool built;
		// First we build the packages
		if (!buildPath(pack, ".no_build").exists && !buildPath(pack, ".no_build_" ~ dc_bin).exists) // For sourceLibrary
		{
			const olddir = getcwd;
			if (de.isDir)
				chdir(pack);
			scope(exit) chdir(olddir);

			if (buildPath(pack, ".fail_build").exists)
			{
				log("Building %s, expected failure...", pack);
				const r = execute(DubCommand.build, dub, pack, dc);
				if (!r.status)
					logError("Error: Failure expected, but build passed.");
			}
			else
			{
				log("Building %s...", pack);
				const r = execute(DubCommand.build, dub, pack, dc);
				if (r.status)
				{
					logError("Build failure.");
				}
				else
					built = true;
			}
		}

		// We run the ones that are supposed to be run
		if (built && !buildPath(pack, ".no_run").exists && !buildPath(pack, ".no_run_" ~ dc_bin).exists)
		{
			log("Running %s...", pack);
			const r = execute(DubCommand.run, dub, pack, dc);
			if (r.status)
			{
				logError("Run failure.");
			}
		}

		// Finally, the unittest part
		if (built && !buildPath(pack, ".no_test").exists && !buildPath(pack, ".no_test_" ~ dc_bin).exists)
		{
			log("Testing %s...", pack);
			const r = execute(DubCommand.test, dub, pack, dc);
			if (r.status)
			{
				logError("Test failure.");
			}
		}
	}

	writeln("\nTesting summary:");
	writeln(readText(logFile));

	return any_errors;
}