/+ dub.sdl:
   name "hash"
 +/

int main()
{
    import std.datetime : dur, SysTime;
    import std.file;
    import std.format : format;
    import std.path;
    import std.process;
    import std.stdio : stderr, writeln;

    enum TestProjectName = "test_project";

    // delete old artifacts if any
    const projectDir = buildPath(getcwd, TestProjectName);
    if (projectDir.exists)
        projectDir.rmdirRecurse;
    projectDir.mkdir;

    chdir(projectDir);

    // create test_project
    {
        auto dub = executeShell("..\\bin\\dub init --non-interactive");
        if (dub.status != 0)
        {
            stderr.writeln("couldn't execute 'dub init test_project'");
            stderr.writeln(dub.output);
            return 1;
        }
    }

    auto buildUsingHash = (bool flag){
        import std.exception : enforce;

        auto dub = executeShell("..\\bin\\dub build --hash=%s".format(flag ? "sha256" : "none"));
        writeln("dub output:");
        import std : lineSplitter;
        foreach(line; dub.output.lineSplitter)
            writeln("\t", line);
        writeln("end of dub output\n---\n");

        enforce(dub.status == 0, "couldn't build the project, see above");
    };

    // build the project first time
    writeln("building #1 (using hash dependent cache)");
    buildUsingHash(true);

    // get time of the artifacts
    SysTime atime, mtime;
    immutable source_name = "source/app.d";
    version(Windows)
        immutable artifact_name = TestProjectName ~ ".exe";
    else
        immutable artifact_name = TestProjectName;

    getTimes(artifact_name, atime, mtime);

    writeln("Current time of the build artifact ", artifact_name, " is: ");
    writeln("access time: ", atime);
    writeln("modify time: ", mtime);
    writeln;

    // touch source/app.d
    setTimes("source/app.d", atime + dur!"seconds"(1), mtime + dur!"seconds"(1));

    writeln("Change time of `source\\app.d to:");
    writeln("access time: ", atime + dur!"seconds"(1));
    writeln("modify time: ", mtime + dur!"seconds"(1));
    writeln;

    writeln("building #2 (using hash dependent cache)");
    buildUsingHash(true);

    // compare time of the artifact to previous value (they should be equal)
    {
        SysTime atime2, mtime2;
        getTimes(artifact_name, atime2, mtime2);

        if (atime == atime2 && mtime == mtime2)
            writeln("Ok. No rebuild triggered");
        else
            writeln("Fail. Rebuild has been triggered");

        assert(atime == atime2);
        assert(mtime == mtime2);
    }

    // edit source/add.d
    // dub build --hash=sha256
    // compare time of the artifact to previous value (the last one should be younger)

    // undo changes in source/app.d (i.e. restore its content)
    // dub build --hash=sha256
    // compare time of the artifact to previous value (the first value and the current one should be equal)

    return 0;
}