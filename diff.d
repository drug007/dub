#!/usr/bin/env dub
/+dub.sdl:
	name: diff
	targetName: diff
+/

int main()
{
	import std;
getcwd.writeln;
	auto l1 = "test/test.log".readText.lineSplitter.array.sort;
	auto l2 = "test/test2.log".readText.lineSplitter.array.sort;

	auto i = setIntersection(l1, l2);
	i.each!writeln;
	writeln("diff");
	string[] d = setSymmetricDifference(l1, l2).array;
	d.each!writeln;
	return d.length == 0 ? 0 : 1;
}