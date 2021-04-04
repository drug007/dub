#!/usr/bin/env dub
/+dub.sdl:
	name: diff
	targetName: diff
+/

int main()
{
	import std;

	auto l1 = "test.log".readText.lineSplitter.array.sort;
	auto l2 = "test2.log".readText.lineSplitter.array.sort;

	auto i = setIntersection(l1, l2);
	i.each!writeln;
	writeln("diff");
	string[] d = setSymmetricDifference(l1, l2).array;
	d.each!writeln;
	return d.length == 0 ? 0 : 1;
}