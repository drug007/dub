#!/usr/bin/env dub
/+dub.sdl:
	name: diff
	targetName: diff
+/

void main()
{
	import std;
	auto l1 = "test/test.log".readText.lineSplitter.array.sort;
	auto l2 = "test/test2.log".readText.lineSplitter.array.sort;

	auto i = setIntersection(l1, l2);
	i.each!writeln;
	writeln("diff");
	string[] d = setSymmetricDifference(l1, l2).array;
	d.each!writeln;
	assert(d.equal([
		"[ERROR] /home/runner/work/dub/dub/test/version-spec.sh:19 command failed",
		"[ERROR] /home/runner/work/dub/dub/test/version-spec.sh:20 command failed",
		"[ERROR] /home/runner/work/dub/dub/test/version-spec.sh:21 command failed",
		"[ERROR] /opt/hostedtoolcache/dc/dmd-2.096.0/x64/dmd2/linux/bin64/dub:19 command failed",
		"[ERROR] /opt/hostedtoolcache/dc/dmd-2.096.0/x64/dmd2/linux/bin64/dub:20 command failed",
		"[ERROR] /opt/hostedtoolcache/dc/dmd-2.096.0/x64/dmd2/linux/bin64/dub:21 command failed",
	]));
}