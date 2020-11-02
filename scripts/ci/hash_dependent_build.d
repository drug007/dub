/+ dub.sdl:
   name "hash"
 +/

import std.algorithm : any;
import std.array : array;
import std.string : lineSplitter;
import std.datetime : dur, SysTime;
import std.file;
import std.format : format;
import std.path;
import std.process;
import std.stdio : stderr, writeln;

enum TestProjectName = "hash-dependent-build";
immutable source_name = "source/app.d";
version(Windows) immutable artifact_name = TestProjectName ~ ".exe";
else             immutable artifact_name = TestProjectName;

auto buildUsingHash(bool flag) {
    import std.exception : enforce;

    auto dub = executeShell(buildNormalizedPath("..", "..", "bin", "dub") ~ " build --hash=%s".format(flag ? "sha256" : "none"));
    writeln("dub output:");
    import std.string : lineSplitter;
    foreach(line; dub.output.lineSplitter)
        writeln("\t", line);
    writeln("end of dub output");

    enforce(dub.status == 0, "couldn't build the project, see above");

    return dub.output;
}

// compare time of the artifact to previous value (they should be equal)
auto checkIfNoRebuild(string output) {
    if (output.lineSplitter.any!(a=> a == "hash-dependent-build ~master: target for configuration \"application\" is up to date.")) {
        writeln("\tOk. No rebuild triggered");
        return true;
    }
    else
        writeln("\tFail. Rebuild has been triggered");
    return false;
}

auto checkIfRebuildTriggered(string output) {
    if (output.lineSplitter.any!(a=> a == "hash-dependent-build ~master: building configuration \"application\"...")) {
        writeln("Ok. Rebuild has been triggered");
        return true;
    }
    else
        writeln("Fail. No rebuild triggered");
    return false;
}

int main()
{
    // delete old artifacts if any
    const projectDir = buildPath(getcwd, "test", TestProjectName);
    if (projectDir.exists)
        projectDir.rmdirRecurse;
    projectDir.mkdir;

    chdir(projectDir);

    // create test_project
    {
        auto dub = executeShell(buildNormalizedPath("..", "..", "bin", "dub") ~ " init --non-interactive");
        if (dub.status != 0)
        {
            stderr.writeln("couldn't execute 'dub init test_project'");
            stderr.writeln(dub.output);
            return 1;
        }
    }

    // build the project first time
    writeln("\n---");
    writeln("Build #1 (using hash dependent cache)");
    writeln("Building the project from scratch");
    writeln("Build should be triggered");
    auto output = buildUsingHash(true);
    if (!checkIfRebuildTriggered(output))
        return 1;

    writeln("\n---");
    writeln("Building #2 (using hash dependent cache)");
    writeln("building the project that has been built (using hash dependent cache)");
    writeln("Build should NOT be triggered");
    output = buildUsingHash(true);
    if (!checkIfNoRebuild(output))
        return 1;

    // touch some source file(s)
    {
        SysTime atime, mtime;
        const delay = dur!"msecs"(10);
        getTimes(artifact_name, atime, mtime);
        setTimes(source_name, atime + delay, mtime + delay);

        writeln("Change time of `source\\app.d to:");
        writeln("access time: ", atime + delay);
        writeln("modify time: ", mtime + delay);
        writeln;

        // wait for the delay to avoid time related issues
        import core.thread : Thread;
        Thread.sleep(delay);
    }

    writeln("\n---");
    writeln("Build #3 (using hash dependent cache)");
    writeln("building the project that has been built (using hash dependent cache)");
    writeln("but timestamp of source file(s) has been changed to be younger");
    writeln("Build should NOT be triggered");
    output = buildUsingHash(true);
    if (!checkIfNoRebuild(output))
        return 1;

    writeln("\n---");
    writeln("build #4 (using time dependent cache)");
    writeln("building the project that has been built (using hash dependent cache)");
    writeln("but timestamp of source file(s) has been changed to be younger");
    writeln("Build should be triggered");
    output = buildUsingHash(false);
    if (!checkIfRebuildTriggered(output))
        return 1;

    // edit some source file(s) preserving the file timestamp
    {
        SysTime atime, mtime;
        getTimes(source_name, atime, mtime);

        auto src = readText(source_name);
        src ~= " ";
        import std.file;
        write(source_name, src);

        setTimes(source_name, atime, mtime);
    }

    writeln("\n---");
    writeln("build #5 (using time dependent cache)");
    writeln("building the project that has been built (using both hash- and time- dependent cache)");
    writeln("but source file(s) has been changed and timestamp of them was preserved");
    writeln("Build should NOT be triggered");
    output = buildUsingHash(false);
    if (!checkIfNoRebuild(output))
        return 1;

    writeln("\n---");
    writeln("build #6 (using hash dependent cache)");
    writeln("building the project that has been built once (using both hash- and time- dependent cache)");
    writeln("but source file(s) has been changed and timestamp of them was preserved");
    writeln("Build should be triggered");
    output = buildUsingHash(true);
    if (!checkIfRebuildTriggered(output))
        return 1;

    // undo changes in source/app.d (i.e. restore its content)
    // dub build --hash=sha256
    // compare time of the artifact to previous value (the first value and the current one should be equal)

    return 0;
}