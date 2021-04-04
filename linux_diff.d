#!/usr/bin/env dub
/+dub.sdl:
	name: linux-diff
	targetName: linux-diff
+/

void main()
{
	import std;
	auto l1 = "test/test.log".readText.lineSplitter.array.sort;
	auto l2 = "test/test2.log".readText.lineSplitter.array.sort;

	string[] d = setSymmetricDifference(l1, l2).array;
	d.each!writeln;
	version(Posix)
		assert(d.length == 0);
	else
		static assert(0);
}