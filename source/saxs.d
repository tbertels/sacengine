import dagon;
import util;
import sxmd,sxsk,sxtx;

import std.stdio, std.path, std.string, std.exception, std.algorithm, std.range, std.conv, std.math;

struct Bone{
	Vector3f position;
	size_t parent;
}

struct Position{
	size_t bone;
	Vector3f offset;
	float weight;
}

struct Vertex{
	private int[3] indices_;
	Vector2f uv;
	this(R)(R indices, Vector2f uv){
		this.indices=indices;
		this.uv=uv;
	}
	@property int[] indices(){
		foreach(i;0..3){
			if(indices_[i]==-1)
				return indices_[0..i];
		}
		return indices_[];
	}
	@property void indices(R)(R range){
		auto len=range.walkLength;
		copy(range,indices[0..len]);
		indices[len..$]=-1;
	}
}

struct BodyPart{
	Vertex[] vertices;
	uint[3][] faces;
	Texture texture;
}

struct Saxs{
	Bone[] bones;
	Position[] positions;
	BodyPart[] bodyParts;
}

Saxs loadSaxs(string filename){
	enforce(filename.endsWith(".SXMD"));
	auto dir=dirName(filename);
	ubyte[] data;
	foreach(ubyte[] chunk;chunks(File(filename,"rb"),4096)) data~=chunk;
	auto model = parseSXMD(data);
	auto bones=chain(only(Bone(Vector3f(0,0,0),0)),model.bones.map!(bone=>Bone(Vector3f(fromSXMD(bone.pos)),bone.parent))).array;
	enforce(iota(1,bones.length).all!(i=>bones[i].parent<i));
	auto convertPosition(ref sxmd.Position position){
		return Position(position.bone,fromSXMD(Vector3f(position.pos)),position.weight/64.0f);
	}
	auto positions=model.positions.map!convertPosition().array;
	BodyPart[] bodyParts;
	auto vrt=new uint[][][](model.bodyParts.length);
	foreach(i,bodyPart;model.bodyParts){
		Vertex[] vertices;
		vrt[i]=new uint[][](bodyPart.rings.length);
		double textureMax=bodyPart.rings[$-1].texture;
		foreach(j,ring;bodyPart.rings){
			vrt[i][j]=new uint[](ring.entries.length+1);
			foreach(k,entry;ring.entries){
				vrt[i][j][k]=to!uint(vertices.length);
				auto indices=entry.indices[].map!(to!int).filter!(x=>x!=ushort.max);
				auto uv=Vector2f(entry.alignment/256.0f,ring.texture/textureMax);
				if(bodyPart.explicitFaces.length) uv[1]=entry.textureV/256.0f;
				vertices~=Vertex(indices,uv);
			}
			vrt[i][j][ring.entries.length]=to!uint(vertices.length);
			vertices~=vertices[vrt[i][j][0]];
			vertices[$-1].uv[0]=1.0f;
		}
		uint[3][] faces;
		if(bodyPart.flags & BodyPartFlags.CLOSE_TOP){
			foreach(j;1..vrt[i][0].length-1){
				faces~=[vrt[i][0][0],vrt[i][0][j],vrt[i][0][j+1]];
			}
		}
		/+if(i!=0)+/ foreach(j,ring;bodyPart.rings[0..$-1]){
			auto entries=ring.entries;
			auto next=bodyPart.rings[j+1].entries;
			for(int a=0,b=0;a<entries.length||b<next.length;){
				if(b==next.length||a<entries.length&&entries[a].alignment<=next[b].alignment){
					faces~=[vrt[i][j][a],vrt[i][j+1][b],vrt[i][j][a+1]];
					a++;
				}else{
					faces~=[vrt[i][j+1][b],vrt[i][j+1][b+1],vrt[i][j][a]];
					b++;
				}
			}
		}
		if(bodyPart.flags & BodyPartFlags.CLOSE_BOT){
			foreach(j;1..vrt[i][$-1].length-1){
				faces~=[vrt[i][$-1][0],vrt[i][$-1][j+1],vrt[i][$-1][j]];
			}
		}
		if(bodyPart.explicitFaces.length){
			enforce(vrt[i].length==1);
			foreach(eface;bodyPart.explicitFaces)
				faces~=[vrt[i][0][eface[0]],vrt[i][0][eface[1]],vrt[i][0][eface[2]]];
		}
		auto texture=New!Texture(null); // TODO: how not to leak this memory without crashing at shutdown?
		texture.image = loadSXTX(buildPath(dir,format(".%03d.SXTX",i+1)));
		texture.createFromImage(texture.image);
		bodyParts~=BodyPart(vertices,faces,texture);
		if(bodyPart.strips.length){
			// TODO: enforce all in bounds
			// TODO: this is not the right way to interpret this data:
			for(int j=0;j<bodyPart.strips.length;j++){
				if(bodyPart.strips[j].bodyPart==i&&j+1<bodyPart.strips.length){
					auto strip1=bodyPart.strips[j];
					auto idx1=vrt[strip1.bodyPart][strip1.ring][strip1.vertex];
					auto strip2=bodyPart.strips[j+1];
					auto idx2=vrt[strip2.bodyPart][strip2.ring][strip2.vertex];
					//writeln(bodyParts.length," ",bodyPart.strips[j+1].bodyPart);
					bodyParts[strip1.bodyPart].vertices[idx1].indices_=bodyParts[strip2.bodyPart].vertices[idx2].indices_;
				}
			}
			/+
			auto vrts=bodyPart.strips.map!(strip=>bodyParts[strip.bodyPart].vertices[vrt[strip.bodyPart][strip.ring][strip.vertex]]);
			bodyParts[$-1].vertices~=chain(vrts,vrts).array;
			auto ind1=iota(to!uint(bodyParts[$-1].vertices.length-2*bodyPart.strips.length),to!uint(bodyParts[$-1].vertices.length-bodyPart.strips.length));
			auto ind2=iota(to!uint(bodyParts[$-1].vertices.length-bodyPart.strips.length),to!uint(bodyParts[$-1].vertices.length));
			foreach(j;0..bodyPart.strips.length){
				// TODO: is there a way to figure out what the orientation should be?
				bodyParts[$-1].faces~=[ind1[j],ind1[(j+1)%$],ind1[(j+2)%$]];
				bodyParts[$-1].faces~=[ind2[j],ind2[(j+2)%$],ind2[(j+1)%$]];
				//if(j&1) swap(bodyParts[$-1].faces[$-1][1],bodyParts[$-1].faces[$-1][2]);
				//bodyParts[$-1].faces~=[ind[j],ind[(j+2)%$],ind[(j+1)%$]];
			}+/
		}
	}
	//writeln("numVertices: ",std.algorithm.sum(bodyParts.map!(bodyPart=>bodyPart.vertices.length)));
	//writeln("numFaces: ",std.algorithm.sum(bodyParts.map!(bodyPart=>bodyPart.vertices.length)));
	return Saxs(bones,positions,bodyParts);
}

Mesh[] createMeshes(Saxs saxs,float scaleFactor=0.005){
	auto ap = new Vector3f[](saxs.bones.length);
	ap[0]=Vector3f(0,0,0);
	foreach(i,ref bone;saxs.bones[1..$]){
		ap[i+1]=bone.position;
		ap[i+1]+=ap[bone.parent];
	}
	auto meshes=new Mesh[](saxs.bodyParts.length);
	foreach(i,ref bodyPart;saxs.bodyParts){
		meshes[i]=new Mesh(null);
		meshes[i].vertices=New!(Vector3f[])(bodyPart.vertices.length);
		meshes[i].texcoords=New!(Vector2f[])(bodyPart.vertices.length);
		foreach(j,ref vertex;bodyPart.vertices){
			auto position=Vector3f(0,0,0);
			foreach(v;vertex.indices.map!(k=>(ap[saxs.positions[k].bone]+saxs.positions[k].offset)*saxs.positions[k].weight))
				position+=v;
			meshes[i].vertices[j]=position*scaleFactor;
			meshes[i].texcoords[j]=vertex.uv;
		}
		meshes[i].indices=New!(uint[3][])(bodyPart.faces.length);
		meshes[i].indices[]=bodyPart.faces[];
		meshes[i].normals=New!(Vector3f[])(bodyPart.vertices.length);
		meshes[i].generateNormals();
		meshes[i].dataReady=true;
		meshes[i].prepareVAO();
	}
	return meshes;
}

struct SaxsInstance{
	Saxs saxs;
	Mesh[] meshes;
}

void createMeshes(ref SaxsInstance saxsi){
	saxsi.meshes=createMeshes(saxsi.saxs);
}

void createEntities(ref SaxsInstance saxsi, Scene s){
	foreach(i,ref bodyPart;saxsi.saxs.bodyParts){
		auto obj=s.createEntity3D();
		obj.drawable=saxsi.meshes[i];
		auto mat=s.createMaterial();
		if(bodyPart.texture !is null)
			mat.diffuse=bodyPart.texture;
		obj.material=mat;
	}
}

struct Transformation{
	Quaternionf rotation;
	Vector3f offset;
	this(Quaternionf rotation,Vector3f offset){
		this.rotation=rotation;
		this.offset=offset;
	}
	Vector3f opCall(Vector3f v){
		auto quat=Quaternionf(v[0],v[1],v[2],0.0);
		auto rotated=Vector3f((rotation*quat*rotation.conj())[0..3]);
		return rotated+offset;
	}
	Transformation opBinary(string op:"*")(Transformation rhs){
		return Transformation(rotation*rhs.rotation,opCall(rhs.offset));
	}
}

void setPose(ref SaxsInstance saxsi, Pose pose, float scaleFactor=0.005){
	auto saxs=saxsi.saxs;
	auto transform = new Transformation[](saxs.bones.length);
	transform[0]=Transformation(Quaternionf.identity,Vector3f(0,0,0));
	enforce(pose.rotations.length==saxs.bones.length);
	foreach(i,ref bone;saxs.bones){
		transform[i]=transform[bone.parent]*Transformation(pose.rotations[i],bone.position);
		if(i==0) transform[i].offset+=pose.displacement;
	}
	enforce(saxsi.meshes.length==saxs.bodyParts.length);
	foreach(i,ref bodyPart;saxs.bodyParts){
		enforce(saxsi.meshes[i].vertices.length==bodyPart.vertices.length);
		foreach(j,ref vertex;bodyPart.vertices){
			auto position=Vector3f(0,0,0);
			foreach(k;vertex.indices)
				position+=transform[saxs.positions[k].bone](saxs.positions[k].offset)*saxs.positions[k].weight;
			saxsi.meshes[i].vertices[j]=position*scaleFactor;
		}
		saxsi.meshes[i].generateNormals();
		saxsi.meshes[i].prepareVAO();
	}
}