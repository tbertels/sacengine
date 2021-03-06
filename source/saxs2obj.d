// copyright © tg
// distributed under the terms of the gplv3 license
// https://www.gnu.org/licenses/gpl-3.0.txt

import dagon;
import saxs, sxsk, dagonBackend;
static if(!gpuSkinning):
	import std.algorithm, std.range, std.stdio;

void writeObj(B)(File file,Saxs!B saxs,Pose pose){
	auto saxsi=SaxsInstance!B(saxs);
	saxsi.createMeshes(pose);
	saxsi.setPose(pose);
	auto meshes=saxsi.meshes;
	int numVertices=0;
	foreach(i,mesh;meshes){
		file.writefln!"g bodypart%03d"(i+1);
		file.writefln!"usemtl bodypart%03d"(i+1);
		int firstVertex=numVertices+1;
		foreach(j;0..mesh.vertices.length){
			file.writefln!"v %.10f %.10f %.10f"(mesh.vertices[j].x,mesh.vertices[j].y,mesh.vertices[j].z);
			file.writefln!"vn %.10f %.10f %.10f"(mesh.normals[j].x,mesh.normals[j].y,mesh.normals[j].z);
			file.writefln!"vt %.10f %.10f"(mesh.texcoords[j].x,mesh.texcoords[j].y);
			numVertices++;
		}
		foreach(tri;mesh.indices){
			file.writefln!"f %d %d %d"(firstVertex+tri[0],firstVertex+tri[1],firstVertex+tri[2]);
		}
	}
}
