// copyright © tg
// distributed under the terms of the gplv3 license
// https://www.gnu.org/licenses/gpl-3.0.txt

import sacobject;
import dlib.math.portable;
import std.stdio;
import std.exception, std.conv, std.algorithm, std.format, std.string, std.path;
import std.typecons: Tuple, tuple;
import util;

struct Face{
	uint unknown0;
	uint[3] vertices;
	uint[2] unknown1;
	float[3] normal;
	float[2][3] uv;
	char[4] retroName;
	string textureName(){
		auto tmp=retroName;
		reverse(tmp[]);
		return cast(string)tmp[].dup;
	}
}
static assert(Face.sizeof==64);

struct Model{
	float[3][] positions;
	float[3][] normals;
	float[2][] uv;
	Face[] faces;
}

Model parse3DSM(ubyte[] data){
	uint numVertices=(cast(uint[])data[0..4])[0];
	enforce(data[0..4]==data[4..8]);
	uint vertexOff=0x9c;
	auto positions=cast(float[3][])data[vertexOff..vertexOff+(float[3]).sizeof*numVertices];
	auto normals=cast(float[3][])data[vertexOff+(float[3]).sizeof*numVertices..vertexOff+2*(float[3]).sizeof*numVertices];
	uint faceOff=to!uint(vertexOff+2*(float[3]).sizeof*numVertices);
	uint numFaces=(cast(uint[])data[8..12])[0];
	enforce(faceOff+Face.sizeof*numFaces==data.length);
	auto faces=cast(Face[])data[faceOff..faceOff+Face.sizeof*numFaces];
	auto uv=new float[2][](positions.length);
	foreach(ref face;faces){
		foreach(i;0..3){
			auto vertex=face.vertices[i];
			enforce(0 <= face.vertices[i] && face.vertices[i]<positions.length);
			enforce(uv[vertex][].all!isNaN || uv[vertex]==face.uv[i]);
			uv[vertex]=face.uv[i];
		}
	}
	return Model(positions,normals,uv,faces);
}

Tuple!(B.Mesh[], B.Texture[]) load3DSM(B)(string filename, float scaling){
	enforce(filename.endsWith(".3DSM"));
	auto dir = dirName(filename);
	auto model = parse3DSM(readFile(filename));
	return convertModel!B(dir, model, scaling);
}
