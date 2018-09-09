import dagon;
import util;

import std.stdio, std.exception, std.algorithm, std.array;

struct Pose{
	Vector3f displacement;
	Quaternionf[] rotations;
}
private struct FrameHeader{
	short unknown;
	short[2] disp;
	uint offset;
}
static assert(FrameHeader.sizeof==12);

struct Animation{
	Pose[] frames;
}

Animation parseSXSK(ubyte[] data){
	alias T=float;
	auto numFrames=*cast(ushort*)data[2..4].ptr;
	double offsetY=*cast(float*)data[4..8].ptr;
	auto numBones=*data[8..12].ptr;
	auto frameHeaders=cast(FrameHeader[])data[12..12+numFrames*FrameHeader.sizeof];
	Pose[] frames;
	foreach(i,ref frameHeader;frameHeaders){
		enforce(frameHeader.offset<=frameHeader.offset+numBones*(short[4]).sizeof && frameHeader.offset+numBones*(short[4]).sizeof<=data.length);
		auto anim=cast(short[4][])data[frameHeader.offset..frameHeader.offset+numBones*(short[4]).sizeof];
		auto rotations=anim.map!(x=>Quaternionf(cast(T)x[0]/short.max,cast(T)x[1]/short.max,cast(T)x[2]/short.max,cast(T)x[3]/short.max)).array;
		frames~=Pose(Vector3f(frameHeader.disp[0],frameHeader.disp[1],0),rotations);
	}
	return Animation(frames);
}

Animation loadSXSK(string filename){
	enforce(filename.endsWith(".SXSK"));
	ubyte[] data;
	foreach(ubyte[] chunk;chunks(File(filename,"rb"),4096)) data~=chunk;
	return parseSXSK(data);
}
