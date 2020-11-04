/+ dub.sdl:
   name "hash"
 +/

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

    auto dub = executeShell("..\\..\\bin\\dub build --hash=%s".format(flag ? "sha256" : "none"));
    writeln("dub output:");
    import std : lineSplitter;
    foreach(line; dub.output.lineSplitter)
        writeln("\t", line);
    writeln("end of dub output\n---\n");

    enforce(dub.status == 0, "couldn't build the project, see above");

    return dub.output;
}

// compare time of the artifact to previous value (they should be equal)
auto checkIfNoRebuild(string output) {
    import std.array : array;
    import std.string : lineSplitter;
    auto lines = output.lineSplitter.array;

    if (lines[$-2] == "hash-dependent-build ~master: target for configuration \"application\" is up to date." &&
        lines[$-1] == "To force a rebuild of up-to-date targets, run again with --force.") {
        writeln("Ok. No rebuild triggered");
        return true;
    }
    else
        writeln("Fail. Rebuild has been triggered");
    return false;
}

auto checkIfRebuildTriggered(string output) {
    import std.array : array;
    import std.string : lineSplitter;
    auto lines = output.lineSplitter.array;
    if (lines[$-2] == "hash-dependent-build ~master: building configuration \"application\"..." && 
        lines[$-1] == "Linking...") {
        writeln("Fail. No rebuild triggered");
        return false;
    }
    else
        writeln("Ok. Rebuild has been triggered");
    return true;
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
        auto dub = executeShell("..\\..\\bin\\dub init --non-interactive");
        if (dub.status != 0)
        {
            stderr.writeln("couldn't execute 'dub init test_project'");
            stderr.writeln(dub.output);
            return 1;
        }
    }

    // build the project first time
    writeln("building #1 (using hash dependent cache)");
    buildUsingHash(true);

    // touch some source file(s)
    {
        SysTime atime, mtime;
        getTimes(artifact_name, atime, mtime);
        setTimes(source_name, atime + dur!"seconds"(1), mtime + dur!"seconds"(1));

        writeln("Change time of `source\\app.d to:");
        writeln("access time: ", atime + dur!"seconds"(1));
        writeln("modify time: ", mtime + dur!"seconds"(1));
        writeln;
    }

    writeln("building #2 (using hash dependent cache)");
    auto output = buildUsingHash(true);
    if (!checkIfNoRebuild(output))
        return 1;

    writeln("building #3 (using time dependent cache)");
    output = buildUsingHash(false);
    if (checkIfRebuildTriggered(output))
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

        SysTime a, m;
        getTimes(source_name, a, m);
        writeln(atime, "\t", mtime);
        writeln(a, "\t", m);
    }
    
    // writeln("building #4 (using time dependent cache)");
    // buildUsingHash(false);
    // checkIfNoRebuild;
    
    // writeln("building #5 (using hash dependent cache)");
    // buildUsingHash(true);
    // checkIfRebuildTriggered;

    // undo changes in source/app.d (i.e. restore its content)
    // dub build --hash=sha256
    // compare time of the artifact to previous value (the first value and the current one should be equal)

    return 0;
}