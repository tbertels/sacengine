import std.algorithm, std.range;
import std.container.array: Array;
import std.exception, std.stdio, std.conv, std.math;
import dlib.math, dlib.image.color;
import std.typecons;
import sids, ntts, nttData, bldg, sset;
import sacmap, sacobject, animations, sacspell;
import stats;
import util,options;
enum int updateFPS=60;
static assert(updateFPS%animFPS==0);
enum updateAnimFactor=updateFPS/animFPS;

struct Id{
	RenderMode mode;
	int type;
	int index=-1;
}

enum CreatureMode{
	idle,
	moving,
	dying,
	dead,
	dissolving,
	preSpawning,
	spawning,
	reviving,
	fastReviving,
	takeoff,
	landing,
	meleeMoving,
	meleeAttacking,
	stunned,
	cower,
	casting,
	stationaryCasting,
	castingMoving,
}

bool isMoving(CreatureMode mode){
	with(CreatureMode) return !!mode.among(moving,meleeMoving,castingMoving);
}
bool isCasting(CreatureMode mode){
	with(CreatureMode) return !!mode.among(casting,stationaryCasting,castingMoving);
}

enum CreatureMovement{
	onGround,
	flying,
	tumbling,
}

enum MovementDirection{
	none,
	forward,
	backward,
}

enum RotationDirection:ubyte{
	none,
	left,
	right,
}
enum PitchingDirection:ubyte{
	none,
	up,
	down,
}

struct CreatureState{
	auto mode=CreatureMode.idle;
	auto movement=CreatureMovement.onGround;
	float facing=0.0f, targetFlyingHeight=float.nan, flyingPitch=0.0f;
	auto movementDirection=MovementDirection.none;
	auto rotationDirection=RotationDirection.none;
	auto pitchingDirection=PitchingDirection.none;
	auto fallingVelocity=Vector3f(0.0f,0.0f,0.0f);
	auto speedLimit=float.infinity; // for xy-plane only, in meters _per frame_
	auto rotationSpeedLimit=float.infinity; // for xy-plane only, in radians _per frame_
	auto pitchingSpeedLimit=float.infinity; // _in radians _per frame_
	int timer; // used for: constraining revive time to be at least 5s, time until casting finished
	int timer2; // used for: time until incantation finished
}

struct OrderTarget{
	TargetType type;
	int id;
	Vector3f position;
	this(TargetType type,int id,Vector3f position){
		this.type=type;
		this.id=id;
		this.position=position;
	}
	this(Target target){
		this(target.type,target.id,target.position);
	}
}

struct Order{
	CommandType command;
	OrderTarget target; // TODO: don't store TargetLocation in creature state
	float targetFacing=0.0f;
	auto formationOffset=Vector2f(0.0f,0.0f);
}

Vector3f getTargetPosition(B)(ref Order order,ObjectState!B state){
	auto targetPosition=order.target.position;
	auto targetFacing=order.targetFacing;
	auto formationOffset=order.formationOffset;
	return getTargetPosition(targetPosition,targetFacing,formationOffset,state);
}

Vector3f getTargetPosition(B)(Vector3f targetPosition,float targetFacing,Vector2f formationOffset,ObjectState!B state){
	targetPosition+=rotate(facingQuaternion(targetFacing), Vector3f(formationOffset.x,formationOffset.y,0));
	targetPosition.z=state.getHeight(targetPosition);
	return targetPosition;
}

enum Formation{
	line,
	flankLeft,
	flankRight,
	phalanx,
	semicircle,
	circle,
	wedge,
	skirmish,
}

Vector2f[numCreaturesInGroup] getFormationOffsets(R)(R ids,CommandType commandType,Formation formation,Vector2f formationScale,Vector2f targetScale){
	auto unitDistance=1.75f*max(formationScale.x,formationScale.y);
	auto targetDistance=1.75f*max(targetScale.x,targetScale.y);
	if(targetDistance!=0.0f) targetDistance=max(targetDistance, unitDistance);
	auto numCreatures=ids.until(0).walkLength;
	Vector2f[numCreaturesInGroup] result=Vector2f(0,0);
	static immutable float sqrt2=sqrt(2.0f);
	final switch(formation){
		case Formation.line:
			auto offset=-0.5f*(numCreatures-1)*unitDistance;
			foreach(i;0..numCreatures) result[i]=Vector2f(offset+unitDistance*i,0.0f);
			if(targetDistance!=0.0f && commandType!=commandType.attack){
				if(numCreatures&1){
					foreach(i;0..numCreatures){
						if(i<(numCreatures+1)/2) result[i].x-=targetDistance;
						else result[i].x+=targetDistance-unitDistance;
					}
				}else{
					foreach(i;0..numCreatures){
						if(i<numCreatures/2) result[i].x-=targetDistance-0.5f*unitDistance;
						else result[i].x+=targetDistance-0.5f*unitDistance;
					}
				}
			}
			break;
		case Formation.flankLeft:
			auto offset=-(numCreatures*unitDistance);
			foreach(i;0..numCreatures) result[i]=Vector2f(offset+unitDistance*i,0.0f);
			if(targetDistance!=0.0f && commandType!=commandType.attack){
				foreach(i;0..numCreatures)
					result[i].x-=targetDistance-unitDistance;
			}
			break;
		case Formation.flankRight:
			auto offset=unitDistance;
			foreach(i;0..numCreatures) result[i]=Vector2f(offset+unitDistance*i,0.0f);
			if(targetDistance!=0.0f && commandType!=commandType.attack){
				foreach(i;0..numCreatures)
					result[i].x+=targetDistance-unitDistance;
			}
			break;
		case Formation.phalanx:
			foreach(row;0..3){
				auto numCreaturesInRow=min(max(0,numCreatures-row*4),4);
				auto offset=Vector2f(-0.5f*(numCreaturesInRow-1)*unitDistance,-row*unitDistance);
				foreach(i;0..numCreaturesInRow) result[4*row+i]=offset+Vector2f(unitDistance*i,0.0f);
			}
			if(targetDistance!=0.0f && commandType==commandType.guard){
				foreach(i;0..numCreatures) result[i].y-=2.0f*targetDistance;
			}
			break;
		case Formation.semicircle:
			auto radius=max(targetDistance,0.5f*unitDistance,(numCreatures-1)*unitDistance/cast(float)PI);
			foreach(i;0..numCreatures){
				auto angle=numCreatures==1?0.5f*cast(float)PI:cast(float)PI*i/(numCreatures-1);
				result[i]=radius*Vector2f(-cos(angle),-sin(angle));
			}
			break;
		case Formation.circle:
			auto radius=max(targetDistance,numCreatures*unitDistance/(2.0f*cast(float)PI));
			foreach(i;0..numCreatures){
				auto angle=2.0f*cast(float)PI*i/numCreatures;
				result[i]=radius*Vector2f(-cos(angle),-sin(angle));
			}
			break;
		case Formation.wedge:
			auto scale=max(unitDistance,targetDistance/1.5f);
			auto offset=Vector2f(0.0f,commandType==CommandType.attack?0.0f:3.0f*0.5f*sqrt2*scale);
			foreach(i;0..numCreatures/2+1)
				result[i]=offset-(numCreatures/2-i)*0.5f*Vector2f(sqrt2,sqrt2)*scale;
			foreach(i;numCreatures/2+1..numCreatures)
				result[i]=offset+(i-numCreatures/2)*0.5f*Vector2f(sqrt2,-sqrt2)*scale;
			break;
		case Formation.skirmish:
			auto offset=-0.5f*(numCreatures-1)*unitDistance;
			auto dist=0.5f*sqrt2*unitDistance;
			foreach(i;0..numCreatures) result[i]=Vector2f(offset+unitDistance*i,(i&1)?-dist:0.0f);
			if(targetDistance!=0.0f && commandType==commandType.guard){
				foreach(i;0..numCreatures) result[i].y+=targetDistance+dist;
			}
			break;
	}
	return result;
}

struct CreatureAI{
	Order order;
	Formation formation;
	bool isColliding=false;
}

struct MovingObject(B){
	SacObject!B sacObject;
	int id=0;
	Vector3f position;
	Quaternionf rotation;
	AnimationState animationState;
	int frame;
	CreatureAI creatureAI;
	CreatureState creatureState;
	CreatureStats creatureStats;
	int side=0;
	int soulId=0;

	this(SacObject!B sacObject,Vector3f position,Quaternionf rotation,AnimationState animationState,int frame,CreatureState creatureState,CreatureStats creatureStats,int side){
		this.sacObject=sacObject;
		this.position=position;
		this.rotation=rotation;
		this.animationState=animationState;
		this.frame=frame;
		this.creatureAI=creatureAI;
		this.creatureState=creatureState;
		this.creatureStats=creatureStats;
		this.side=side;
	}
	this(SacObject!B sacObject,int id,Vector3f position,Quaternionf rotation,AnimationState animationState,int frame,CreatureState creatureState,CreatureStats creatureStats,int side){
		this.id=id;
		this(sacObject,position,rotation,animationState,frame,creatureState,creatureStats,side);
	}
	this(SacObject!B sacObject,int id,Vector3f position,Quaternionf rotation,AnimationState animationState,int frame,CreatureAI creatureAI,CreatureState creatureState,CreatureStats creatureStats,int side,int soulId){
		this.creatureAI=creatureAI;
		this.soulId=soulId;
		this(sacObject,id,position,rotation,animationState,frame,creatureState,creatureStats,side);
	}
}
int side(B)(ref MovingObject!B object,ObjectState!B state){
	return object.side;
}
float health(B)(ref MovingObject!B object){
	return object.creatureStats.health;
}
float health(B)(ref MovingObject!B object,ObjectState!B state){
	return object.health;
}
void health(B)(ref MovingObject!B object,float value){
	object.creatureStats.health=value;
}
float speedOnGround(B)(ref MovingObject!B object,ObjectState!B state){
	return object.creatureStats.movementSpeed(false);
}
float speedInAir(B)(ref MovingObject!B object,ObjectState!B state){
	return object.creatureStats.movementSpeed(true);
}
float speed(B)(ref MovingObject!B object,ObjectState!B state){
	return object.creatureState.movement==CreatureMovement.flying?object.speedInAir(state):object.speedOnGround(state);
}
float takeoffTime(B)(ref MovingObject!B object,ObjectState!B state){
	return object.sacObject.takeoffTime;
}
bool isWizard(B)(ref MovingObject!B obj){ return obj.sacObject.isWizard; }
bool isPeasant(B)(ref MovingObject!B obj){ return obj.sacObject.isPeasant; }
bool canSelect(B)(ref MovingObject!B obj,int side,ObjectState!B state){
	return obj.side==side&&!obj.isWizard&&!obj.isPeasant&&!obj.creatureState.mode.among(CreatureMode.dead,CreatureMode.dissolving);
}
bool canOrder(B)(ref MovingObject!B obj,int side,ObjectState!B state){
	return (side==-1||obj.side==side)&&!obj.creatureState.mode.among(CreatureMode.dead,CreatureMode.dissolving);
}
bool canSelect(B)(int side,int id,ObjectState!B state){
	return state.movingObjectById!(canSelect,()=>false)(id,side,state);
}
bool isAggressive(B)(ref MovingObject!B obj,ObjectState!B state){
	return obj.sacObject.isAggressive;
}
float aggressiveRange(B)(ref MovingObject!B obj,CommandType type,ObjectState!B state){
	return obj.sacObject.aggressiveRange;
}
float advanceRange(B)(ref MovingObject!B obj,CommandType type,ObjectState!B state){
	return obj.sacObject.aggressiveRange;
}
bool isMeleeAttacking(B)(ref MovingObject!B obj,ObjectState!B state){
	return !!obj.creatureState.mode.among(CreatureMode.meleeAttacking,CreatureMode.meleeMoving);
}
void select(B)(MovingObject!B obj,ObjectState!B state){
	state.addToSelection(obj.side,obj.id);
}
void unselect(B)(MovingObject!B obj,ObjectState!B state){
	state.removeFromSelection(obj.side,obj.id);
}
void removeFromGroups(B)(MovingObject!B obj,ObjectState!B state){
	state.removeFromGroups(obj.side,obj.id);
}
Vector3f[2] relativeHitbox(B)(ref MovingObject!B object){
	return object.sacObject.hitbox(object.rotation,object.animationState,object.frame/updateAnimFactor);
}
Vector3f[2] hitbox(B)(ref MovingObject!B object){
	auto hitbox=object.relativeHitbox;
	hitbox[0]+=object.position;
	hitbox[1]+=object.position;
	return hitbox;
}
Vector3f[2] closestHitbox(B)(ref MovingObject!B object,Vector3f position){
	return object.hitbox;
}
Vector3f[2] hitbox2d(B)(ref MovingObject!B object,Matrix4f modelViewProjectionMatrix){
	return object.sacObject.hitbox2d(object.animationState,object.frame/updateAnimFactor,modelViewProjectionMatrix);
}

Vector3f relativeCenter(T)(ref T object){
	auto hbox=object.relativeHitbox;
	return 0.5f*(hbox[0]+hbox[1]);
}

Vector3f center(T)(ref T object){
	auto hbox=object.hitbox;
	return 0.5f*(hbox[0]+hbox[1]);
}

Vector3f[2] relativeMeleeHitbox(B)(ref MovingObject!B object){
	return object.sacObject.meleeHitbox(object.rotation,object.animationState,object.frame/updateAnimFactor);
}
Vector3f[2] meleeHitbox(B)(ref MovingObject!B object){
	auto hitbox=object.relativeMeleeHitbox;
	hitbox[0]+=object.position;
	hitbox[1]+=object.position;
	return hitbox;
}

Vector3f soulPosition(B)(ref MovingObject!B object){
	return object.center+rotate(object.rotation,object.sacObject.soulDisplacement);
}

float meleeStrength(B)(ref MovingObject!B object){
	return object.sacObject.meleeStrength;
}

int numAttackTicks(B)(ref MovingObject!B object,AnimationState animationState){
	return object.sacObject.numAttackTicks(animationState);
}

bool hasAttackTick(B)(ref MovingObject!B object){
	return object.frame%updateAnimFactor==0 && object.sacObject.hasAttackTick(object.animationState,object.frame/updateAnimFactor);
}

StunBehavior stunBehavior(B)(ref MovingObject!B object){
	return object.sacObject.stunBehavior;
}

StunnedBehavior stunnedBehavior(B)(ref MovingObject!B object){
	return object.sacObject.stunnedBehavior;
}

bool isRegenerating(B)(ref MovingObject!B object){
	return object.creatureState.mode==CreatureMode.idle||object.sacObject.continuousRegeneration&&!object.creatureState.mode.among(CreatureMode.dying,CreatureMode.dead,CreatureMode.dissolving);
}

bool isDamaged(B)(ref MovingObject!B object){
	return object.health<=0.25f*object.creatureStats.maxHealth;
}

struct StaticObject(B){
	SacObject!B sacObject;
	int id=0;
	int buildingId=0;
	Vector3f position;
	Quaternionf rotation;
	this(SacObject!B sacObject,int buildingId,Vector3f position,Quaternionf rotation){
		this.sacObject=sacObject;
		this.buildingId=buildingId;
		this.position=position;
		this.rotation=rotation;
	}
	this(SacObject!B sacObject,int id,int buildingId,Vector3f position,Quaternionf rotation){
		this.id=id;
		this(sacObject,buildingId,position,rotation);
	}
}
float healthFromBuildingId(B)(int buildingId,ObjectState!B state){
	return state.buildingById!((ref b)=>b.health,function int(){ assert(0); })(buildingId);
}
float health(B)(ref StaticObject!B object,ObjectState!B state){
	return healthFromBuildingId(object.buildingId,state);
}
int sideFromBuildingId(B)(int buildingId,ObjectState!B state){
	return state.buildingById!((ref b)=>b.side,function int(){ assert(0); })(buildingId);
}
int flagsFromBuildingId(B)(int buildingId,ObjectState!B state){
	return state.buildingById!((ref b)=>b.flags,function int(){ assert(0); })(buildingId);
}
bool isActive(B)(ref StaticObject!B object,ObjectState!B state){
	return !(flagsFromBuildingId(object.buildingId,state)&AdditionalBuildingFlags.inactive);
}
int side(B)(ref StaticObject!B object,ObjectState!B state){
	return sideFromBuildingId(object.buildingId,state);
}
auto relativeHitboxes(B)(ref StaticObject!B object){
	return object.sacObject.hitboxes(object.rotation);
}
auto hitboxes(B)(ref StaticObject!B object){
	return object.sacObject.hitboxes(object.rotation).zip(repeat(object.position)).map!(function Vector3f[2](x)=>[x[0][0]+x[1],x[0][1]+x[1]]);
}

Vector3f[2] relativeHitbox(B)(ref StaticObject!B object){
	Vector3f[2] result=[Vector3f(float.max,float.max,float.max),Vector3f(-float.max,-float.max,-float.max)];
	foreach(hitbox;object.relativeHitboxes){
		foreach(i;0..3){
			result[0][i]=min(result[0][i],hitbox[0][i]);
			result[1][i]=max(result[1][i],hitbox[1][i]);
		}
	}
	if(result[1].z>=0) result[0].z=max(result[0].z,0.0f);
	return result;
}
Vector3f[2] closestHitbox(B)(ref StaticObject!B object,Vector3f position){
	Vector3f[2] result;
	auto resultDistSqr=float.infinity;
	foreach(hitbox;object.hitboxes){
		if(hitbox[1].z>=0) hitbox[0].z=max(hitbox[0].z,object.position.z);
		auto candDistSqr=(boxCenter(hitbox)-position).lengthsqr;
		if(candDistSqr<resultDistSqr){
			result=hitbox;
			resultDistSqr=candDistSqr;
		}
	}
	return result;
}
Vector3f[2] hitbox(B)(ref StaticObject!B object){
	auto hitbox=object.relativeHitbox;
	hitbox[0]+=object.position;
	hitbox[1]+=object.position;
	return hitbox;
}
Vector3f[2] hitbox2d(B)(ref StaticObject!B object,Matrix4f modelViewProjectionMatrix){
	return object.sacObject.hitbox2d(object.rotation,modelViewProjectionMatrix);
}

struct FixedObject(B){
	SacObject!B sacObject;
	Vector3f position;
	Quaternionf rotation;

	this(SacObject!B sacObject,Vector3f position,Quaternionf rotation){
		this.sacObject=sacObject;
		this.position=position;
		this.rotation=rotation;
	}
}


enum SoulState{
	normal,
	emerging,
	reviving,
	collecting,
}

struct Soul(B){
	int id=0;
	int creatureId=0;
	int preferredSide=-1;
	int collectorId=0;
	int number;
	Vector3f position;
	SoulState state;
	int frame=0;
	float facing=0.0f;
	float scaling=1.0f;

	this(int number,Vector3f position,SoulState state){
		this.number=number;
		this.position=position;
		this.state=state;
		if(state==SoulState.emerging) scaling=0.0f;
	}
	this(int creatureId,int preferredSide,int number,Vector3f position,SoulState state){
		this.creatureId=creatureId;
		this.preferredSide=preferredSide;
		this(number,position,state);
	}
	this(int id,int creatureId,int preferredSide,int number,Vector3f position,SoulState state){
		this.id=id;
		this.preferredSide=preferredSide;
		this(creatureId,preferredSide,number,position,state);
	}
}

int side(B)(ref Soul!B soul,ObjectState!B state){
	if(soul.creatureId==0) return -1;
	return soul.preferredSide;
}
int soulSide(B)(int id,ObjectState!B state){
	return state.soulById!(side,function int(){ assert(0); })(id,state);
}
SoulColor color(B)(ref Soul!B soul,int side,ObjectState!B state){
	auto soulSide=soul.side(state);
	return soulSide==-1||soulSide==side?SoulColor.blue:SoulColor.red;
}
SoulColor color(B)(int id,int side,ObjectState!B state){
	return state.soulById!(color,function SoulColor(){ assert(0); })(id,side,state);
}

Vector3f[2] hitbox2d(B)(ref Soul!B soul,Matrix4f modelViewProjectionMatrix){
	auto topLeft=Vector3f(-SacSoul!B.soulWidth/2,-SacSoul!B.soulHeight/2,0.0f)*soul.scaling;
	auto bottomRight=-topLeft;
	return [transform(modelViewProjectionMatrix,topLeft),transform(modelViewProjectionMatrix,bottomRight)];
}

enum AdditionalBuildingFlags{
	none=0,
	inactive=32, // TODO: make sure this doesn't clash with anything
}
struct Building(B){
	immutable(Bldg)* bldg; // TODO: replace by SacBuilding class
	int id=0;
	int side;
	Array!int componentIds;
	int flags=0;
	float facing=0.0f;
	int top=0;
	int base=0;
	float health=0.0f;
	enum regeneration=80.0f;
	enum meleeResistance=1.5f;
	enum directSpellResistance=1.0f;
	enum splashSpellResistance=1.0f;
	enum directRangedResistance=1.0f;
	enum splashRangedResistance=1.0f;
	this(immutable(Bldg)* bldg,int side,int flags,float facing){
		this.bldg=bldg;
		this.side=side;
		this.flags=flags;
		this.facing=facing;
		this.health=bldg.maxHealth;
	}
	void opAssign(ref Building!B rhs){
		this.bldg=rhs.bldg;
		this.id=rhs.id;
		this.side=rhs.side;
		assignArray(componentIds,rhs.componentIds);
		health=rhs.health;
		flags=rhs.flags;
		facing=rhs.facing;
		top=rhs.top;
		base=rhs.base;
	}
}
int maxHealth(B)(ref Building!B building,ObjectState!B state){
	return building.bldg.maxHealth;
}
Vector3f position(B)(ref Building!B building,ObjectState!B state){
	return state.staticObjectById!((obj)=>obj.position,function Vector3f(){ assert(0); })(building.componentIds[0]);
}
float height(B)(ref Building!B building,ObjectState!B state){
	float maxZ=0.0f;
	foreach(cid;building.componentIds){
		state.staticObjectById!((obj,state){
			auto hitbox=obj.hitbox;
			maxZ=max(maxZ,hitbox[1].z-obj.position.z);
		})(cid,state);
	}
	return maxZ;
}
// TODO: the following functionality is duplicated in SacObject
bool isManafount(immutable(Bldg)* bldg){ // TODO: store in SacBuilding class
	return bldg.header.numComponents==1&&manafountTags.canFind(bldg.components[0].tag);
}
bool isManafount(B)(ref Building!B building){
	return building.bldg.isManafount;
}
bool isManalith(immutable(Bldg)* bldg){ // TODO: store in SacBuilding class
	return bldg.header.numComponents==1&&manalithTags.canFind(bldg.components[0].tag);
}
bool isManalith(B)(ref Building!B building){
	return building.bldg.isManalith;
}
bool isShrine(immutable(Bldg)* bldg){ // TODO: store in SacBuilding class
	return bldg.header.numComponents==1&&shrineTags.canFind(bldg.components[0].tag);
}
bool isShrine(B)(ref Building!B building){
	return building.bldg.isShrine;
}
bool isAltar(immutable(Bldg)* bldg){ // TODO: store in SacBuilding class
	return bldg.header.numComponents>=1&&altarBaseTags.canFind(bldg.components[0].tag);
}
bool isAltar(B)(ref Building!B building){
	return building.bldg.isAltar;
}
bool isStratosAltar(immutable(Bldg)* bldg){ // TODO: store in SacBuilding class
	return bldg.header.numComponents>=1&&bldg.components[0].tag=="tprc";
}
bool isStratosAltar(B)(ref Building!B building){
	return building.bldg.isStratosAltar;
}
bool isEtherealAltar(immutable(Bldg)* bldg){ // TODO: store in SacBuilding class
	return bldg.header.numComponents>=1&&bldg.components[0].tag=="b_ae";
}
bool isEtherealAltar(B)(ref Building!B building){
	return building.bldg.isEtherealAltar;
}
bool isPeasantShelter(immutable(Bldg)* bldg){
	return !!(bldg.header.flags&BldgFlags.shelter)||bldg.isAltar;
}
bool isPeasantShelter(B)(ref Building!B building){
	return building.bldg.isPeasantShelter;
}

void putOnManafount(B)(ref Building!B building,ref Building!B manafount,ObjectState!B state)in{
	assert(manafount.isManafount);
	assert(building.base==0);
}do{
	if(manafount.top!=0) freeManafount(manafount,state); // original engine associates last building with the fountain
	manafount.top=building.id;
	building.base=manafount.id;
	manafount.stopSounds(state);
}
void freeManafount(B)(ref Building!B manafount,ObjectState!B state)in{
	assert(manafount.isManafount);
	assert(manafount.top!=0);
}do{
	state.buildingById!((ref obj){ assert(obj.base==manafount.id); obj.base=0; })(manafount.top);
	manafount.top=0;
	manafount.loopingSoundSetup(state);
}
void loopingSoundSetup(B)(ref Building!B building,ObjectState!B state){
	static if(B.hasAudio){
		if(building.flags&AdditionalBuildingFlags.inactive) return;
		if(building.isManafount&&building.top!=0) return;
		if(playAudio){
			foreach(cid;building.componentIds)
				state.staticObjectById!(B.loopingSoundSetup)(cid);
		}
	}
}
void stopSounds(B)(ref Building!B building,ObjectState!B state){
	static if(B.hasAudio){
		if(playAudio){
			foreach(cid;building.componentIds)
				stopSoundsAt(cid,state);
		}
	}
}
void activate(B)(ref Building!B building,ObjectState!B state){
	if(!(building.flags&AdditionalBuildingFlags.inactive)) return;
	building.flags&=~AdditionalBuildingFlags.inactive;
	loopingSoundSetup(building,state);
}

struct Particle(B){
	SacParticle!B sacParticle;
	Vector3f position;
	Vector3f velocity;
	int lifetime;
	int frame;
	this(SacParticle!B sacParticle,Vector3f position,Vector3f velocity,int lifetime,int frame){
		this.sacParticle=sacParticle;
		this.position=position;
		this.velocity=velocity;
		this.lifetime=lifetime;
		this.frame=frame;
	}
}

struct MovingObjects(B,RenderMode mode){
	enum renderMode=mode;
	SacObject!B sacObject;
	Array!int ids;
	Array!Vector3f positions;
	Array!Quaternionf rotations;
	Array!AnimationState animationStates;
	Array!int frames;
	Array!CreatureAI creatureAIs;
	Array!CreatureState creatureStates;
	Array!CreatureStats creatureStatss;
	Array!int sides;
	Array!int soulIds;
	@property int length(){ assert(ids.length<=int.max); return cast(int)ids.length; }
	@property void length(int l){
		ids.length=l;
		positions.length=l;
		rotations.length=l;
		animationStates.length=l;
		frames.length=l;
		creatureAIs.length=l;
		creatureStates.length=l;
		creatureStatss.length=l;
		sides.length=l;
		soulIds.length=l;
	}

	void reserve(int reserveSize){
		ids.reserve(reserveSize);
		positions.reserve(reserveSize);
		rotations.reserve(reserveSize);
		animationStates.reserve(reserveSize);
		frames.reserve(reserveSize);
		creatureAIs.reserve(reserveSize);
		creatureStates.reserve(reserveSize);
		creatureStatss.reserve(reserveSize);
		sides.reserve(reserveSize);
		soulIds.reserve(reserveSize);
	}

	void addObject(MovingObject!B object)in{
		assert(object.id!=0);
	}do{
		assert(!sacObject||sacObject is object.sacObject);
		sacObject=object.sacObject;
		ids~=object.id;
		positions~=object.position;
		rotations~=object.rotation;
		animationStates~=object.animationState;
		frames~=object.frame;
		creatureAIs~=object.creatureAI;
		creatureStates~=object.creatureState;
		creatureStatss~=object.creatureStats;
		sides~=object.side;
		soulIds~=object.soulId;
	}
	void removeObject(int index, ObjectManager!B manager){
		manager.ids[ids[index]-1]=Id.init;
		if(index+1<length){
			this[index]=this[length-1];
			manager.ids[ids[index]-1].index=index;
		}
		length=length-1;
	}
	void opAssign(ref MovingObjects!(B,mode) rhs){
		assert(sacObject is null || sacObject is rhs.sacObject);
		sacObject = rhs.sacObject;
		assignArray(ids,rhs.ids);
		assignArray(positions,rhs.positions);
		assignArray(rotations,rhs.rotations);
		assignArray(animationStates,rhs.animationStates);
		assignArray(frames,rhs.frames);
		assignArray(creatureAIs,rhs.creatureAIs);
		assignArray(creatureStates,rhs.creatureStates);
		assignArray(creatureStatss,rhs.creatureStatss);
		assignArray(sides,rhs.sides);
		assignArray(soulIds,rhs.soulIds);
	}
	MovingObject!B opIndex(int i){
		return MovingObject!B(sacObject,ids[i],positions[i],rotations[i],animationStates[i],frames[i],creatureAIs[i],creatureStates[i],creatureStatss[i],sides[i],soulIds[i]);
	}
	void opIndexAssign(MovingObject!B obj,int i){
		assert(obj.sacObject is sacObject);
		ids[i]=obj.id;
		positions[i]=obj.position;
		rotations[i]=obj.rotation;
		animationStates[i]=obj.animationState;
		frames[i]=obj.frame;
		creatureAIs[i]=obj.creatureAI;
		creatureStates[i]=obj.creatureState;
		creatureStatss[i]=obj.creatureStats; // TODO: this might be a bit wasteful
		sides[i]=obj.side;
		soulIds[i]=obj.soulId;
	}
}
auto each(alias f,B,RenderMode mode,T...)(ref MovingObjects!(B,mode) movingObjects,T args){
	foreach(i;0..movingObjects.length){
		static if(!is(typeof(f(MovingObject.init,args)))){
			// TODO: find a better way to check whether argument taken by reference
			auto obj=movingObjects[i];
			f(obj,args);
			movingObjects[i]=obj;
		}else f(movingObjects[i],args);
	}
}


struct StaticObjects(B,RenderMode mode){
	enum renderMode=mode;
	SacObject!B sacObject;
	Array!int ids;
	Array!int buildingIds;
	Array!Vector3f positions;
	Array!Quaternionf rotations;

	static if(mode==RenderMode.transparent){
		Array!float thresholdZs;
	}
	@property int length(){ assert(ids.length<=int.max); return cast(int)ids.length; }
	@property void length(int l){
		ids.length=l;
		buildingIds.length=l;
		positions.length=l;
		rotations.length=l;
	}
	void addObject(StaticObject!B object)in{
		assert(object.id!=0);
	}do{
		ids~=object.id;
		buildingIds~=object.buildingId;
		positions~=object.position;
		rotations~=object.rotation;
		static if(mode==RenderMode.transparent)
			thresholdZs~=0.0f;
	}
	void removeObject(int index, ObjectManager!B manager){
		manager.ids[ids[index]-1]=Id.init;
		if(index+1<length){
			this[index]=this[length-1];
			manager.ids[ids[index]-1].index=index;
		}
		length=length-1;
	}
	void opAssign(ref StaticObjects!(B,mode) rhs){
		assert(sacObject is null || sacObject is rhs.sacObject);
		sacObject=rhs.sacObject;
		assignArray(ids,rhs.ids);
		assignArray(buildingIds,rhs.buildingIds);
		assignArray(positions,rhs.positions);
		assignArray(rotations,rhs.rotations);
		static if(mode==RenderMode.transparent)
			assignArray(thresholdZs,rhs.thresholdZs);
	}
	StaticObject!B opIndex(int i){
		return StaticObject!B(sacObject,ids[i],buildingIds[i],positions[i],rotations[i]);
	}
	void opIndexAssign(StaticObject!B obj,int i){
		assert(sacObject is obj.sacObject);
		ids[i]=obj.id;
		buildingIds[i]=obj.buildingId;
		positions[i]=obj.position;
		rotations[i]=obj.rotation;
	}
	static if(mode==RenderMode.transparent){
		void setThresholdZ(int i,float thresholdZ){
			thresholdZs[i]=thresholdZ;
		}
	}
}
auto each(alias f,B,RenderMode mode,T...)(ref StaticObjects!(B,mode) staticObjects,T args){
	foreach(i;0..staticObjects.length)
		f(staticObjects[i],args);
}

struct FixedObjects(B){
	enum renderMode=RenderMode.opaque;
	SacObject!B sacObject;
	Array!Vector3f positions;
	Array!Quaternionf rotations;
	@property int length(){ assert(positions.length<=int.max); return cast(int)positions.length; }

	void addFixed(FixedObject!B object)in{
		assert(sacObject==object.sacObject);
	}body{
		positions~=object.position;
		rotations~=object.rotation;
	}
	void opAssign(ref FixedObjects!B rhs){
		assert(sacObject is null || sacObject is rhs.sacObject);
		sacObject=rhs.sacObject;
		assignArray(positions,rhs.positions);
		assignArray(rotations,rhs.rotations);
	}
	FixedObject!B opIndex(int i){
		return FixedObject!B(sacObject,positions[i],rotations[i]);
	}
	void opIndexAssign(StaticObject!B obj,int i){
		positions[i]=obj.position;
		rotations[i]=obj.rotation;
	}
}
auto each(alias f,B,T...)(ref FixedObjects!B fixedObjects,T args){
	foreach(i;0..length)
		f(fixedObjects[i],args);
}

struct Souls(B){
	Array!(Soul!B) souls;
	@property int length(){ return cast(int)souls.length; }
	@property void length(int l){ souls.length=l; }
	void addObject(Soul!B soul){
		souls~=soul;
	}
	void removeObject(int index, ObjectManager!B manager){
		manager.ids[souls[index].id-1]=Id.init;
		if(index+1<length){
			this[index]=this[length-1];
			manager.ids[souls[index].id-1].index=index;
		}
		length=length-1;
	}
	void opAssign(ref Souls!B rhs){
		assignArray(souls,rhs.souls);
	}
	Soul!B opIndex(int i){
		return souls[i];
	}
	void opIndexAssign(Soul!B soul,int i){
		souls[i]=soul;
	}
}
auto each(alias f,B,T...)(ref Souls!B souls,T args){
	foreach(i;0..souls.length){
		static if(!is(typeof(f(Soul.init,args)))){
			// TODO: find a better way to check whether argument taken by reference
			auto soul=souls[i];
			f(soul,args);
			souls[i]=soul;
		}else f(souls[i],args);
	}
}

struct Buildings(B){
	Array!(Building!B) buildings;
	@property int length(){ return cast(int)buildings.length; }
	@property void length(int l){ buildings.length=l; }
	void addObject(Building!B building){
		buildings~=building;
	}
	void removeObject(int index, ObjectManager!B manager){
		manager.ids[buildings[index].id-1]=Id.init;
		if(index+1<length){
			this[index]=this[length-1];
			manager.ids[buildings[index].id-1].index=index;
		}
		length=length-1;
	}
	void opAssign(ref Buildings!B rhs){
		buildings.length=rhs.buildings.length;
		foreach(i;0..buildings.length)
			buildings[i]=rhs.buildings[i];
	}
	Building!B opIndex(int i){
		return buildings[i];
	}
	void opIndexAssign(Building!B building,int i){
		buildings[i]=building;
	}
}
auto each(alias f,B,T...)(ref Buildings!B buildings,T args){
	foreach(i;0..buildings.length){
		static if(!is(typeof(f(Building.init,args)))){
			// TODO: find a better way to check whether argument taken by reference
			auto building=buildings[i];
			f(building,args);
			buildings[i]=building;
		}else f(buildings[i],args);
	}
}

enum maxLevel=9;

struct SpellInfo(B){
	SacSpell!B spell;
	int level;
	float cooldown;
	float maxCooldown;
	bool ready=true;
	int readyFrame=16*updateAnimFactor;
	void setCooldown(float newCooldown){
		if(cooldown==0.0f||newCooldown>maxCooldown) maxCooldown=newCooldown;
		if(newCooldown>cooldown) cooldown=newCooldown;
	}
}
struct Spellbook(B){
	Array!(SpellInfo!B) spells;
	void opAssign(ref Spellbook!B rhs){
		assignArray(spells,rhs.spells);
	}
	void addSpell(int level,SacSpell!B spell){
		spells~=SpellInfo!B(spell,level,0.0f,0.0f);
		if(spells.length>=2&&spells[$-1].spell.spellOrder<spells[$-2].spell.spellOrder) sort();
	}
	void sort(){
		.sort!"a.spell.spellOrder<b.spell.spellOrder"(spells.data);
	}
	SpellInfo!B[] getSpells(){
		return spells.data;
	}
}
enum SpellStatus{
	inexistent,
	invalidTarget,
	lowOnMana,
	mustBeNearBuilding,
	mustBeNearEnemyAltar,
	mustBeConnectedToConversion,
	needMoreSouls,
	outOfRange,
	notReady,
	ready,
}

Spellbook!B getDefaultSpellbook(B)(God god){
	Spellbook!B result;
	foreach(tag;neutralCreatures)
		result.addSpell(0,SacSpell!B.get(tag));
	foreach(tag;neutralSpells)
		result.addSpell(0,SacSpell!B.get(tag));
	foreach(tag;structureSpells[0..$-1])
		result.addSpell(0,SacSpell!B.get(tag));
	if(god==God.none){
		result.addSpell(3,SacSpell!B.get(structureSpells[$-1]));
		return result;
	}
	enforce(creatureSpells[god].length==11);
	enforce(normalSpells[god].length==11);
	foreach(lv;1..9+1){
		if(lv==3) result.addSpell(3,SacSpell!B.get(structureSpells[$-1]));
		if(lv==1){
			foreach(tag;creatureSpells[god][1..4])
				result.addSpell(lv,SacSpell!B.get(tag));
			result.addSpell(lv,SacSpell!B.get(normalSpells[god][lv+1]));
		}else if(lv<8){
			result.addSpell(lv,SacSpell!B.get(creatureSpells[god][lv+2]));
			result.addSpell(lv,SacSpell!B.get(normalSpells[god][lv+1]));
		}else if(lv==8){
			foreach(tag;normalSpells[god][9..11])
				result.addSpell(lv,SacSpell!B.get(tag));
		}else if(lv==9){
			result.addSpell(lv,SacSpell!B.get(creatureSpells[god][lv+1]));
		}
	}
	return result;
}

struct WizardInfo(B){
	int id;
	int level;
	int souls;
	float experience;
	Spellbook!B spellbook;

	void opAssign(ref WizardInfo!B rhs){
		id=rhs.id;
		level=rhs.level;
		souls=rhs.souls;
		experience=rhs.experience;
		spellbook=rhs.spellbook;
	}
	void addSpell(int level,SacSpell!B spell){
		spellbook.addSpell(level,spell);
	}
	auto getSpells(){
		return spellbook.getSpells();
	}
}
void applyCooldown(B)(ref WizardInfo!B wizard,SacSpell!B spell,ObjectState!B state){
	enum genericCooldown=1.0f;
	enum additionalCooldown=1.5f;
	foreach(ref entry;wizard.spellbook.spells.data){
		if(entry.spell is spell) entry.setCooldown(spell.castingTime(wizard.level)+spell.cooldown+additionalCooldown);
		else entry.setCooldown(spell.castingTime(wizard.level)+genericCooldown+additionalCooldown);
	}
}
WizardInfo!B makeWizard(B)(int id,int level,int souls,Spellbook!B spellbook,ObjectState!B state){
	state.movingObjectById!((ref wizard,level,state){
		wizard.creatureStats.maxHealth+=50.0f*level;
		wizard.creatureStats.health+=50.0f*level;
		wizard.creatureStats.mana+=100*level;
		wizard.creatureStats.maxMana+=100*level;
		// TODO: boons
	})(id,level,state);
	return WizardInfo!B(id,level,souls,0.0f,spellbook);
}
struct WizardInfos(B){
	Array!(WizardInfo!B) wizards;
	@property int length(){ assert(wizards.length<=int.max); return cast(int)wizards.length; }
	@property void length(int l){
		wizards.length=l;
	}
	void addWizard(WizardInfo!B wizard){
		wizards~=wizard;
	}
	void removeWizard(int id){
		auto index=indexForId(id);
		if(index!=-1){
			if(index+1<wizards.length)
				swap(wizards[index],wizards[$-1]);
			wizards.length=wizards.length-1;
		}
	}
	void opAssign(ref WizardInfos!B rhs){
		assignArray(wizards,rhs.wizards);
	}
	WizardInfo!B opIndex(int i){
		return wizards[i];
	}
	int indexForId(int id){
		foreach(i;0..wizards.length) if(wizards[i].id==id) return cast(int)i;
		return -1;
	}
	WizardInfo!B* getWizard(int id){
		auto index=indexForId(id);
		if(index==-1) return null;
		return &wizards[index];
	}
}
auto each(alias f,B,T...)(ref WizardInfos!B wizards,T args){
	foreach(i;0..wizards.length){
		static if(!is(typeof(f(WizardInfo.init,args)))){
			// TODO: find a better way to check whether argument taken by reference
			auto wizard=wizards[i];
			f(wizard,args);
			wizards[i]=wizard;
		}else f(wizards[i],args);
	}
}

struct Particles(B){
	SacParticle!B sacParticle;
	Array!Vector3f positions;
	Array!Vector3f velocities;
	Array!int lifetimes;
	Array!int frames;
	@property int length(){ assert(positions.length<=int.max); return cast(int)positions.length; }
	@property void length(int l){
		positions.length=l;
		velocities.length=l;
		lifetimes.length=l;
		frames.length=l;
	}
	void reserve(int reserveSize){
		positions.reserve(reserveSize);
		velocities.reserve(reserveSize);
		lifetimes.reserve(reserveSize);
		frames.reserve(reserveSize);
	}
	void addParticle(Particle!B particle){
		assert(sacParticle is null || sacParticle is particle.sacParticle);
		sacParticle=particle.sacParticle; // TODO: get rid of this?
		positions~=particle.position;
		velocities~=particle.velocity;
		lifetimes~=particle.lifetime;
		frames~=particle.frame;
	}
	void removeParticle(int index){
		if(index+1<length) this[index]=this[length-1];
		length=length-1;
	}
	void opAssign(ref Particles!B rhs){
		assert(sacParticle is null || sacParticle is rhs.sacParticle);
		sacParticle = rhs.sacParticle;
		assignArray(positions,rhs.positions);
		assignArray(velocities,rhs.velocities);
		assignArray(lifetimes,rhs.lifetimes);
		assignArray(frames,rhs.frames);
	}
	Particle!B opIndex(int i){
		return Particle!B(sacParticle,positions[i],velocities[i],lifetimes[i],frames[i]);
	}
	void opIndexAssign(Particle!B particle,int i){
		assert(particle.sacParticle is sacParticle);
		positions[i]=particle.position;
		velocities[i]=particle.velocity;
		lifetimes[i]=particle.lifetime;
		frames[i]=particle.frame;
	}
}

struct Debris(B){
	Vector3f position; // TODO: better representation?
	Vector3f velocity;
	Quaternionf rotationUpdate;
	Quaternionf rotation;
}
struct Explosion(B){
	Vector3f position;
	float scale,maxScale,expansionSpeed;
	int frame;
}
struct ManaDrain(B){
	int wizard;
	float manaCostPerFrame;
}
struct CreatureCasting(B){
	ManaDrain!B manaDrain;
	SacSpell!B spell;
	int creature;
}
struct StructureCasting(B){
	ManaDrain!B manaDrain;
	SacSpell!B spell;
	int building;
	float buildingHeight;
	int castingTime;
	int currentFrame;
}
struct BlueRing(B){
	Vector3f position;
	float scale=1.0f;
	int frame=0;
}
struct SpeedUp(B){
	int creature;
	int framesLeft;
}
struct SpeedUpShadow(B){
	int creature;
	Vector3f position;
	Quaternionf rotation;
	AnimationState animationState;
	int frame;
	int age=0;
}
struct Effects(B){
	Array!(Debris!B) debris;
	void addEffect(Debris!B debris){
		this.debris~=debris;
	}
	void removeDebris(int i){
		if(i+1<debris.length) swap(debris[i],debris[$-1]);
		debris.length=debris.length-1;
	}
	Array!(Explosion!B) explosions;
	void addEffect(Explosion!B explosion){
		explosions~=explosion;
	}
	void removeExplosion(int i){
		if(i+1<explosions.length) swap(explosions[i],explosions[$-1]);
		explosions.length=explosions.length-1;
	}
	Array!(ManaDrain!B) manaDrains;
	void addEffect(ManaDrain!B manaDrain){
		manaDrains~=manaDrain;
	}
	void removeManaDrain(int i){
		if(i+1<manaDrains.length) swap(manaDrains[i],manaDrains[$-1]);
		manaDrains.length=manaDrains.length-1;
	}
	Array!(CreatureCasting!B) creatureCasts;
	void addEffect(CreatureCasting!B creatureCast){
		creatureCasts~=creatureCast;
	}
	void removeCreatureCasting(int i){
		if(i+1<creatureCasts.length) swap(creatureCasts[i],creatureCasts[$-1]);
		creatureCasts.length=creatureCasts.length-1;
	}
	Array!(StructureCasting!B) structureCasts;
	void addEffect(StructureCasting!B structureCast){
		structureCasts~=structureCast;
	}
	void removeStructureCasting(int i){
		if(i+1<structureCasts.length) swap(structureCasts[i],structureCasts[$-1]);
		structureCasts.length=structureCasts.length-1;
	}
	Array!(BlueRing!B) blueRings;
	void addEffect(BlueRing!B blueRing){
		blueRings~=blueRing;
	}
	void removeBlueRing(int i){
		if(i+1<blueRings.length) swap(blueRings[i],blueRings[$-1]);
		blueRings.length=blueRings.length-1;
	}
	Array!(SpeedUp!B) speedUps;
	void addEffect(SpeedUp!B speedUp){
		speedUps~=speedUp;
	}
	void removeSpeedUp(int i){
		if(i+1<speedUps.length) swap(speedUps[i],speedUps[$-1]);
		speedUps.length=speedUps.length-1;
	}
	Array!(SpeedUpShadow!B) speedUpShadows;
	void addEffect(SpeedUpShadow!B speedUpShadow){
		speedUpShadows~=speedUpShadow;
	}
	void removeSpeedUpShadow(int i){
		if(i+1<speedUpShadows.length) swap(speedUpShadows[i],speedUpShadows[$-1]);
		speedUpShadows.length=speedUpShadows.length-1;
	}
	void opAssign(ref Effects!B rhs){
		assignArray(debris,rhs.debris);
		assignArray(explosions,rhs.explosions);
		assignArray(manaDrains,rhs.manaDrains);
		assignArray(creatureCasts,rhs.creatureCasts);
		assignArray(structureCasts,rhs.structureCasts);
		assignArray(blueRings,rhs.blueRings);
		assignArray(speedUps,rhs.speedUps);
		assignArray(speedUpShadows,rhs.speedUpShadows);
	}
}

struct CommandCone(B){
	int side;
	CommandConeColor color;
	Vector3f position;
	int lifetime=cast(int)(SacCommandCone!B.lifetime*updateFPS);
}
struct CommandCones(B){
	struct CommandConeElement(B){
		Vector3f position;
		int lifetime;
		this(CommandCone!B rhs){
			position=rhs.position;
			lifetime=rhs.lifetime;
		}
	}
	Array!(Array!(CommandConeElement!B)[CommandConeColor.max+1]) cones;
	this(int numSides){
		cones.length=numSides;
	}
	void addCommandCone(CommandCone!B cone){
		cones[cone.side][cone.color]~=CommandConeElement!B(cone);
	}
	void removeCommandCone(int side,CommandConeColor color,int index){
		if(index+1<cones[side][color].length) cones[side][color][index]=cones[side][color][$-1];
		cones[side][color].length=cones[side][color].length-1;
	}
}

struct Objects(B,RenderMode mode){
	Array!(MovingObjects!(B,mode)) movingObjects;
	Array!(StaticObjects!(B,mode)) staticObjects;
	static if(mode == RenderMode.opaque){
		FixedObjects!B[] fixedObjects;
		Souls!B souls;
		Buildings!B buildings;
		WizardInfos!B wizards;
		Array!(Particles!B) particles;
		Effects!B effects;
		CommandCones!B commandCones;
	}
	Id addObject(T)(T object) if(is(T==MovingObject!B)||is(T==StaticObject!B))in{
		assert(object.id!=0);
	}do{
		Id result;
		auto type=object.sacObject.stateIndex[mode];
		if(type==-1){
			static if(is(T==MovingObject!B)){
				type=object.sacObject.stateIndex[mode]=cast(int)movingObjects.length;
				movingObjects.length=movingObjects.length+1;
				movingObjects[$-1].sacObject=object.sacObject;
			}else{
				type=object.sacObject.stateIndex[mode]=cast(int)staticObjects.length+numMoving;
				staticObjects.length=staticObjects.length+1;
				staticObjects[$-1].sacObject=object.sacObject;
			}
		}
		static if(is(T==MovingObject!B)){
			enforce(type<numMoving);
			if(movingObjects.length<=type) movingObjects.length=type+1;
			result=Id(mode,type,movingObjects[type].length);
			movingObjects[type].addObject(object);
		}else{
			enforce(numMoving<=type && type<numMoving+numStatic);
			if(staticObjects.length<=type-numMoving) movingObjects.length=type-numMoving+1;
			result=Id(mode,type,staticObjects[type-numMoving].length);
			staticObjects[type-numMoving].addObject(object);
		}
		return result;
	}
	void removeObject(int type, int index, ref ObjectManager!B manager){
		if(type<numMoving){
			movingObjects[type].removeObject(index,manager);
		}else if(type<numMoving+numStatic){
			staticObjects[type-numMoving].removeObject(index,manager);
		}else static if(mode==RenderMode.opaque){
			final switch(cast(ObjectType)type){
				case ObjectType.soul: souls.removeObject(index,manager); break;
				case ObjectType.building: buildings.removeObject(index,manager); break;
			}
		}else enforce(0);
	}
	static if(mode==RenderMode.transparent){
		void setThresholdZ(int type, int index, float thresholdZ){
			enforce(numMoving<=type&&type<numMoving+numStatic);
			staticObjects[type-numMoving].setThresholdZ(index, thresholdZ);
		}
	}
	static if(mode==RenderMode.opaque){
		void addFixed(FixedObject!B object){
			auto type=object.sacObject.stateIndex[mode];
			if(type==-1){
				type=object.sacObject.stateIndex[mode]=cast(int)fixedObjects.length+numMoving+numStatic;
				fixedObjects.length=fixedObjects.length+1;
				fixedObjects[$-1].sacObject=object.sacObject;
			}
			enforce(numMoving+numStatic<=type);
			if(fixedObjects.length<=type-(numMoving+numStatic)) fixedObjects.length=type-(numMoving+numStatic)+1;
			fixedObjects[type-(numMoving+numStatic)].addFixed(object);
		}
		Id addObject(Soul!B object){
			auto result=Id(mode,ObjectType.soul,souls.length);
			souls.addObject(object);
			return result;
		}
		Id addObject(Building!B object){
			auto result=Id(mode,ObjectType.building,buildings.length);
			buildings.addObject(object);
			return result;
		}
		void addWizard(WizardInfo!B wizard){
			wizards.addWizard(wizard);
		}
		WizardInfo!B* getWizard(int id){
			return wizards.getWizard(id);
		}
		void removeWizard(int id){
			wizards.removeWizard(id);
		}
		void addEffect(T)(T proj){
			effects.addEffect(proj);
		}
		void addParticle(Particle!B particle){
			auto type=particle.sacParticle.stateIndex;
			if(type==-1){
				type=particle.sacParticle.stateIndex=cast(int)particles.length;
				particles.length=particles.length+1;
				particles[$-1].sacParticle=particle.sacParticle;
			}
			if(particles.length<=type) particles.length=type+1;
			particles[type].addParticle(particle);
		}
		void addCommandCone(CommandCone!B cone){
			if(!commandCones.cones.length) commandCones=CommandCones!B(32); // TODO: do this eagerly?
			commandCones.addCommandCone(cone);
		}
	}
	void opAssign(Objects!(B,mode) rhs){
		assignArray(movingObjects,rhs.movingObjects);
		assignArray(staticObjects,rhs.staticObjects);
		static if(mode == RenderMode.opaque){
			fixedObjects=rhs.fixedObjects; // by reference
			souls=rhs.souls;
			buildings=rhs.buildings;
			wizards=rhs.wizards;
			effects=rhs.effects;
			assignArray(particles,rhs.particles);
			commandCones=rhs.commandCones;
		}
	}
}
auto each(alias f,B,RenderMode mode,T...)(ref Objects!(B,mode) objects,T args){
	with(objects){
		static if(mode == RenderMode.opaque){
			foreach(ref staticObject;staticObjects)
				staticObject.each!f(args);
			foreach(ref fixedObject;fixedObjects)
				fixedObject.each!f(args);
			souls.each!f(args);
		}
		foreach(ref movingObject;movingObjects)
			movingObject.each!f(args);
	}
}
auto eachMoving(alias f,B,RenderMode mode,T...)(ref Objects!(B,mode) objects,T args){
	with(objects){
		foreach(ref movingObject;movingObjects)
			movingObject.each!f(args);
	}
}
auto eachStatic(alias f,B,RenderMode mode,T...)(ref Objects!(B,mode) objects,T args){
	static if(mode==RenderMode.opaque) with(objects){
		foreach(ref staticObject;staticObjects)
			staticObject.each!f(args);
	}
}
auto eachSoul(alias f,B,T...)(ref Objects!(B,RenderMode.opaque) objects,T args){
	objects.souls.each!f(args);
}
auto eachBuilding(alias f,B,T...)(ref Objects!(B,RenderMode.opaque) objects,T args){
	objects.buildings.each!f(args);
}
auto eachWizard(alias f,B,T...)(ref Objects!(B,RenderMode.opaque) objects,T args){
	objects.wizards.each!f(args);
}
auto eachEffects(alias f,B,T...)(ref Objects!(B,RenderMode.opaque) objects,T args){
	f(objects.effects,args);
}
auto eachParticles(alias f,B,T...)(ref Objects!(B,RenderMode.opaque) objects,T args){
	with(objects){
		foreach(ref particle;particles)
			f(particle,args);
	}
}
auto eachCommandCones(alias f,B,T...)(ref Objects!(B,RenderMode.opaque) objects,T args){
	f(objects.commandCones,args);
}
auto eachByType(alias f,bool movingFirst=true,B,RenderMode mode,T...)(ref Objects!(B,mode) objects,T args){
	with(objects){
		static if(movingFirst)
			foreach(ref movingObject;movingObjects)
				f(movingObject,args);
		foreach(ref staticObject;staticObjects)
			f(staticObject,args);
		static if(mode == RenderMode.opaque){
			foreach(ref fixedObject;fixedObjects)
				f(fixedObject,args);
			f(souls,args);
			f(buildings,args);
			f(effects,args);
			foreach(ref particle;particles)
				f(particle,args);
			f(commandCones,args);
		}
		static if(!movingFirst)
			foreach(ref movingObject;movingObjects)
				f(movingObject,args);
	}
}
auto eachMovingOf(alias f,B,RenderMode mode,T...)(ref Objects!(B,mode) objects,SacObject!B sacObject,T args){
	with(objects){
		auto index=sacObject.stateIndex[mode];
		if(index==-1||index>=movingObjects.length) return;
		each!f(movingObjects[index],args);
	}
}

enum numMoving=100;
enum numStatic=300;
enum ObjectType{
	soul=numMoving+numStatic,
	building,
}

struct ObjectManager(B){
	Array!Id ids;
	Objects!(B,RenderMode.opaque) opaqueObjects;
	Objects!(B,RenderMode.transparent) transparentObjects;
	int addObject(T)(T object) if(is(T==MovingObject!B)||is(T==StaticObject!B)||is(T==Soul!B)||is(T==Building!B))in{
		assert(object.id==0);
	}do{
		if(ids.length>=int.max) return 0;
		object.id=cast(int)ids.length+1;
		ids~=opaqueObjects.addObject(object);
		return object.id;
	}
	void removeObject(int id)in{
		assert(0<id && id<=ids.length);
	}do{
		auto tid=ids[id-1];
		if(tid==Id.init) return; // already deleted
		scope(success) assert(ids[id-1]==Id.init);
		final switch(tid.mode){
			case RenderMode.opaque: opaqueObjects.removeObject(tid.type,tid.index,this); break;
			case RenderMode.transparent: transparentObjects.removeObject(tid.type,tid.index,this); break;
		}
	}
	void setThresholdZ(int id,float thresholdZ)in{
		assert(0<id && id<=ids.length);
	}do{
		auto tid=ids[id-1];
		enforce(tid.mode==RenderMode.transparent);
		transparentObjects.setThresholdZ(tid.type,tid.index,thresholdZ);
	}
	void setRenderMode(T,RenderMode mode)(int id)if(is(T==MovingObject!B)||is(T==StaticObject!B)){
		auto tid=ids[id-1];
		if(tid.mode==mode) return;
		static if(mode==RenderMode.opaque){
			alias old=transparentObjects;
			alias new_=opaqueObjects;
		}else static if(mode==RenderMode.transparent){
			alias old=opaqueObjects;
			alias new_=transparentObjects;
		}else static assert(0);
		static if(is(T==MovingObject!B)){
			auto obj=this.movingObjectById!((obj)=>obj,function MovingObject!B(){ assert(0); })(id);
		}else{
			auto obj=this.staticObjectById!((obj)=>obj,function StaticObject!B(){ assert(0); })(id);
		}
		old.removeObject(tid.type,tid.index,this);
		ids[id-1]=new_.addObject(obj);
	}
	bool isValidId(int id){
		if(0<id && id<=ids.length)
			return ids[id-1]!=Id.init;
		return false;
	}
	bool isValidId(int id,TargetType type){
		if(0<id && id<=ids.length){
			if(ids[id-1]==Id.init) return false;
			auto objType=ids[id-1].type;
			if(objType<numMoving) return type==TargetType.creature;
			if(objType<numMoving+numStatic) return type==TargetType.building;
			if(objType==ObjectType.soul) return type==TargetType.soul;
			if(objType==ObjectType.building) return type==TargetType.building;
		}
		return false;
	}
	void addTransparent(T)(T object, float alpha){
		assert(0,"TODO");
	}
	void addWizard(WizardInfo!B wizard){
		opaqueObjects.addWizard(wizard);
	}
	WizardInfo!B* getWizard(int id){
		return opaqueObjects.getWizard(id);
	}
	void removeWizard(int id){
		opaqueObjects.removeWizard(id);
	}
	void addFixed(FixedObject!B object){
		opaqueObjects.addFixed(object);
	}
	void addEffect(T)(T proj){
		opaqueObjects.addEffect(proj);
	}
	void addParticle(Particle!B particle){
		opaqueObjects.addParticle(particle);
	}
	void addCommandCone(CommandCone!B cone){
		opaqueObjects.addCommandCone(cone);
	}

	void opAssign(ObjectManager!B rhs){
		assignArray(ids,rhs.ids);
		opaqueObjects=rhs.opaqueObjects;
		transparentObjects=rhs.transparentObjects;
	}
}
auto each(alias f,B,T...)(ref ObjectManager!B objectManager,T args){
	with(objectManager){
		opaqueObjects.each!f(args);
		transparentObjects.each!f(args);
	}
}
auto eachMoving(alias f,B,T...)(ref ObjectManager!B objectManager,T args){
	with(objectManager){
		opaqueObjects.eachMoving!f(args);
		transparentObjects.eachMoving!f(args);
	}
}
auto eachStatic(alias f,B,T...)(ref ObjectManager!B objectManager,T args){
	with(objectManager){
		opaqueObjects.eachStatic!f(args);
		transparentObjects.eachStatic!f(args);
	}
}
auto eachSoul(alias f,B,T...)(ref ObjectManager!B objectManager,T args){
	with(objectManager) opaqueObjects.eachSoul!f(args);
}
auto eachBuilding(alias f,B,T...)(ref ObjectManager!B objectManager,T args){
	with(objectManager) opaqueObjects.eachBuilding!f(args);
}
auto eachWizard(alias f,B,T...)(ref ObjectManager!B objectManager,T args){
	with(objectManager) opaqueObjects.eachWizard!f(args);
}
auto eachEffects(alias f,B,T...)(ref ObjectManager!B objectManager,T args){
	with(objectManager) opaqueObjects.eachEffects!f(args);
}
auto eachParticles(alias f,B,T...)(ref ObjectManager!B objectManager,T args){
	with(objectManager) opaqueObjects.eachParticles!f(args);
}
auto eachCommandCones(alias f,B,T...)(ref ObjectManager!B objectManager,T args){
	with(objectManager) opaqueObjects.eachCommandCones!f(args);
}
auto eachByType(alias f,bool movingFirst=true,B,T...)(ref ObjectManager!B objectManager,T args){
	with(objectManager){
		opaqueObjects.eachByType!(f,movingFirst)(args);
		transparentObjects.eachByType!(f,movingFirst)(args);
	}
}
auto eachMovingOf(alias f,B,T...)(ref ObjectManager!B objectManager,SacObject!B sacObject,T args){
	with(objectManager){
		opaqueObjects.eachMovingOf!f(sacObject,args);
		transparentObjects.eachMovingOf!f(sacObject,args);
	}
}
auto ref objectById(alias f,B,T...)(ref ObjectManager!B objectManager,int id,T args)in{
	assert(id>0);
}do{
	auto nid=objectManager.ids[id-1];
	assert(nid!=Id.init);
	if(nid.type<numMoving){
		enum byRef=!is(typeof(f(MovingObject!B.init,args))); // TODO: find a better way to check whether argument taken by reference!
		final switch(nid.mode){
			case RenderMode.opaque:
				static if(byRef){
					auto obj=objectManager.opaqueObjects.movingObjects[nid.type][nid.index];
					scope(success) objectManager.opaqueObjects.movingObjects[nid.type][nid.index]=obj;
					return f(obj,args);
				}else return f(objectManager.opaqueObjects.movingObjects[nid.type][nid.index],args);
			case RenderMode.transparent:
				static if(byRef){
					auto obj=objectManager.transparentObjects.movingObjects[nid.type][nid.index];
					scope(success) objectManager.transparentObjects.movingObjects[nid.type][nid.index]=obj;
					return f(obj,args);
				}else return f(objectManager.transparentObjects.movingObjects[nid.type][nid.index],args);
		}
	}else{
		enum byRef=!is(typeof(f(StaticObject!B.init,args))); // TODO: find a better way to check whether argument taken by reference!
		assert(nid.type<numMoving+numStatic);
		final switch(nid.mode){
			case RenderMode.opaque:
				static if(byRef){
					auto obj=objectManager.opaqueObjects.staticObjects[nid.type-numMoving][nid.index];
					scope(success) objectManager.opaqueObjects.staticObjects[nid.type-numMoving][nid.index]=obj;
					return f(obj,args);
				}else return f(objectManager.opaqueObjects.staticObjects[nid.type-numMoving][nid.index],args);
			case RenderMode.transparent:
				static if(byRef){
					auto obj=objectManager.transparentObjects.staticObjects[nid.type-numMoving][nid.index];
					scope(success) objectManager.transparentObjects.staticObjects[nid.type-numMoving][nid.index]=obj;
					return f(obj,args);
				}else return f(objectManager.transparentObjects.staticObjects[nid.type-numMoving][nid.index],args);
		}
	}
}
auto ref movingObjectById(alias f,alias nonMoving=fail,B,T...)(ref ObjectManager!B objectManager,int id,T args)in{
	assert(id>0);
}do{
	auto nid=objectManager.ids[id-1];
	enum byRef=!is(typeof(f(MovingObject!B.init,args))); // TODO: find a better way to check whether argument taken by reference!
	if(nid.type<numMoving&&nid.index!=-1){
		final switch(nid.mode){ // TODO: get rid of code duplication
			case RenderMode.opaque:
				static if(byRef){
					auto obj=objectManager.opaqueObjects.movingObjects[nid.type][nid.index];
					scope(success) objectManager.opaqueObjects.movingObjects[nid.type][nid.index]=obj;
					return f(obj,args);
				}else return f(objectManager.opaqueObjects.movingObjects[nid.type][nid.index],args);
			case RenderMode.transparent:
				static if(byRef){
					auto obj=objectManager.transparentObjects.movingObjects[nid.type][nid.index];
					scope(success) objectManager.transparentObjects.movingObjects[nid.type][nid.index]=obj;
					return f(obj,args);
				}else return f(objectManager.transparentObjects.movingObjects[nid.type][nid.index],args);
		}
	}else return nonMoving();
}
auto ref staticObjectById(alias f,alias nonStatic=fail,B,T...)(ref ObjectManager!B objectManager,int id,T args)in{
	assert(id>0);
}do{
	auto nid=objectManager.ids[id-1];
	enum byRef=!is(typeof(f(StaticObject!B.init,args))); // TODO: find a better way to check whether argument taken by reference!
	if(nid.type<numMoving||nid.index==-1) return nonStatic();
	else if(nid.type<numMoving+numStatic){
		final switch(nid.mode){
			case RenderMode.opaque:
				static if(byRef){
					auto obj=objectManager.opaqueObjects.staticObjects[nid.type-numMoving][nid.index];
					scope(success) objectManager.opaqueObjects.staticObjects[nid.type-numMoving][nid.index]=obj;
					return f(obj,args);
				}else return f(objectManager.opaqueObjects.staticObjects[nid.type-numMoving][nid.index],args);
			case RenderMode.transparent:
				static if(byRef){
					auto obj=objectManager.transparentObjects.staticObjects[nid.type-numMoving][nid.index];
					scope(success) objectManager.transparentObjects.staticObjects[nid.type-numMoving][nid.index]=obj;
					return f(obj,args);
				}else return f(objectManager.transparentObjects.staticObjects[nid.type-numMoving][nid.index],args);
		}
	}else return nonStatic();
}
auto ref soulById(alias f,alias noSoul=fail,B,T...)(ref ObjectManager!B objectManager,int id,T args)in{
	assert(id>0);
}do{
	auto nid=objectManager.ids[id-1];
	if(nid.type!=ObjectType.soul||nid.index==-1) return noSoul();
	enum byRef=!is(typeof(f(Soul!B.init,args))); // TODO: find a better way to check whether argument taken by reference!
	static if(byRef){
		auto soul=objectManager.opaqueObjects.souls[nid.index];
		scope(success) objectManager.opaqueObjects.souls[nid.index]=soul;
		return f(soul,args);
	}else return f(objectManager.opaqueObjects.souls[nid.index],args);
}
auto ref buildingById(alias f,alias noBuilding=fail,B,T...)(ref ObjectManager!B objectManager,int id,T args)in{
	assert(id>0);
}do{
	auto nid=objectManager.ids[id-1];
	if(nid.type!=ObjectType.building||nid.index==-1) return noBuilding();
	enum byRef=!is(typeof(f(Building!B.init,args))); // TODO: find a better way to check whether argument taken by reference!
	static if(byRef){
		auto building=objectManager.opaqueObjects.buildings[nid.index];
		scope(success) objectManager.opaqueObjects.buildings[nid.index]=building;
		return f(building,args);
	}else return f(objectManager.opaqueObjects.buildings[nid.index],args);
}
auto ref buildingByStaticObjectId(alias f,alias nonStatic=fail,B,T...)(ref ObjectManager!B objectManager,int id,T args)in{
	assert(id>0);
}do{
	auto nid=objectManager.ids[id-1];
	enum byRef=!is(typeof(f(StaticObject!B.init,args))); // TODO: find a better way to check whether argument taken by reference!
	if(nid.type<numMoving||nid.index==-1) return nonStatic();
	else if(nid.type<numMoving+numStatic){
		assert(nid.mode==RenderMode.opaque);
		assert(nid.type<numMoving+numStatic);
		static if(byRef){
			auto obj=objectManager.opaqueObjects.staticObjects[nid.type-numMoving][nid.index];
			scope(success) objectManager.opaqueObjects.staticObjects[nid.type-numMoving][nid.index]=obj;
			assert(obj.buildingId);
			return objectManager.buildingById!(f,nonStatic)(obj.buildingId,args);
		}else return f(objectManager.opaqueObjects.staticObjects[nid.type-numMoving][nid.index],args);
	}else return nonStatic();
}

void setCreatureState(B)(ref MovingObject!B object,ObjectState!B state){
	auto sacObject=object.sacObject;
	final switch(object.creatureState.mode){
		case CreatureMode.idle:
			object.creatureState.timer=0;
			bool isDamaged=object.isDamaged;
			if(object.creatureState.movement!=CreatureMovement.flying){
				if(object.animationState.among(AnimationState.run,AnimationState.walk) && object.creatureState.timer<0.1f*updateFPS)
					break;
				object.frame=0;
			}
			if(object.frame==0){
				if(isDamaged&&sacObject.hasAnimationState(AnimationState.stance2))
					object.animationState=AnimationState.stance2;
				else object.animationState=AnimationState.stance1;
			}
			if(sacObject.mustFly) object.creatureState.movement=CreatureMovement.flying;
			final switch(object.creatureState.movement){
				case CreatureMovement.onGround:
					break;
				case CreatureMovement.flying:
					assert(sacObject.canFly);
					if(!sacObject.mustFly && (object.frame==0||object.animationState==AnimationState.fly&&sacObject.seamlessFlyAndHover))
						object.animationState=AnimationState.hover;
					break;
				case CreatureMovement.tumbling:
					object.creatureState.mode=CreatureMode.stunned;
					break;
			}
			if(object.creatureState.mode==CreatureMode.stunned)
				goto case CreatureMode.stunned;
			if(object.frame==0&&!state.uniform(5)){ // TODO: figure out the original rule for this
				with(AnimationState) if(sacObject.mustFly){
					if(isDamaged&&sacObject.hasAnimationState(idle2)){
						object.animationState=idle2;
					}else{
						static immutable idleCandidatesFlying=[hover,idle0,idle1,idle3]; // TODO: maybe idle3 has a special precondition, like idle2?
						object.pickRandomAnimation(idleCandidatesFlying,state);
					}
				}else if(object.creatureState.movement==CreatureMovement.onGround){
					if(isDamaged&&sacObject.hasAnimationState(idle2)){
						object.animationState=idle2;
					}else{
						static immutable idleCandidatesOnGround=[idle0,idle1,idle3]; // TODO: maybe idle3 has a special precondition, like idle2 ?
						object.pickRandomAnimation(idleCandidatesOnGround,state);
					}
				}
			}
			if(object.id&&object.frame==0&&!state.uniform(5)) // TODO: figure out the original rule for this
				playSoundTypeAt(sacObject,object.id,SoundType.idleTalk,state);
			break;
		case CreatureMode.moving:
			final switch(object.creatureState.movement) with(CreatureMovement){
				case onGround:
					if(!sacObject.canRun){
						if(sacObject.canFly) object.startFlying(state);
						else object.startIdling(state);
						return;
					}
					if(object.animationState!=AnimationState.run){
						object.frame=0;
						object.animationState=AnimationState.run;
					}
					break;
				case flying:
					if(object.frame==0||object.animationState==AnimationState.hover&&sacObject.seamlessFlyAndHover)
						object.animationState=AnimationState.fly;
					break;
				case tumbling:
					object.creatureState.mode=CreatureMode.stunned;
					break;
			}
			if(object.creatureState.mode==CreatureMode.stunned)
				goto case CreatureMode.stunned;
			break;
		case CreatureMode.dying:
			with(AnimationState){
				static immutable deathCandidatesOnGround=[death0,death1,death2];
				static immutable deathCandidatesFlying=[flyDeath,death0,death1,death2];
				if(sacObject.mustFly||!deathCandidatesOnGround.canFind(object.animationState)){
					object.frame=0;
					final switch(object.creatureState.movement) with(CreatureMovement){
						case onGround:
							assert(!sacObject.mustFly);
							object.pickRandomAnimation(deathCandidatesOnGround,state);
							break;
						case flying:
							if(sacObject.mustFly){
								object.pickRandomAnimation(deathCandidatesFlying,state);
							}else object.animationState=flyDeath;
							break;
						case tumbling:
							object.animationState=sacObject.hasFalling?falling:sacObject.canTumble?tumble:stance1;
							break;
					}
				}
			}
			break;
		case CreatureMode.preSpawning,CreatureMode.spawning:
			object.frame=0;
			if(sacObject.hasAnimationState(AnimationState.disoriented))
				object.animationState=AnimationState.disoriented;
			else object.animationState=AnimationState.stance1;
			break;
		case CreatureMode.dead:
			object.animationState=AnimationState.death0;
			if(sacObject.mustFly)
				object.animationState=AnimationState.hitFloor;
			object.frame=sacObject.numFrames(object.animationState)*updateAnimFactor-1;
			break;
		case CreatureMode.dissolving:
			object.creatureState.timer=0;
			break;
		case CreatureMode.reviving, CreatureMode.fastReviving:
			assert(object.frame==sacObject.numFrames(object.animationState)*updateAnimFactor-1);
			static immutable reviveSequence=[AnimationState.corpse,AnimationState.float_];
			object.creatureState.timer=0;
			if(sacObject.hasAnimationState(AnimationState.corpse)){
				object.frame=0;
				object.animationState=AnimationState.corpse;
			}else if(sacObject.hasAnimationState(AnimationState.float_)){
				object.frame=0;
				object.animationState=AnimationState.float_;
			}
			break;
		case CreatureMode.takeoff:
			assert(sacObject.canFly && object.creatureState.movement==CreatureMovement.onGround);
			if(!sacObject.hasAnimationState(AnimationState.takeoff)){
				object.creatureState.movement=CreatureMovement.flying;
				object.creatureState.speedLimit=0.0f;
				if(sacObject.movingAfterTakeoff){
					object.creatureState.mode=CreatureMode.moving;
					goto case CreatureMode.moving;
				}else{
					object.creatureState.mode=CreatureMode.idle;
					goto case CreatureMode.idle;
				}
			}
			object.frame=0;
			object.animationState=AnimationState.takeoff;
			break;
		case CreatureMode.landing:
			if(object.frame==0){
				if(object.creatureState.movement==CreatureMovement.onGround){
					object.creatureState.mode=CreatureMode.idle;
					goto case CreatureMode.idle;
				}else if(object.position.z<=state.getGroundHeight(object.position)){
					object.creatureState.movement=CreatureMovement.onGround;
					if(!sacObject.hasAnimationState(AnimationState.land)){
						object.creatureState.mode=CreatureMode.idle;
						goto case CreatureMode.idle;
					}
					object.animationState=AnimationState.land;
				}else object.animationState=AnimationState.hover;
			}
			break;
		case CreatureMode.meleeMoving,CreatureMode.meleeAttacking:
			playSoundTypeAt(sacObject,object.id,SoundType.melee,state);
			final switch(object.creatureState.movement) with(CreatureMovement) with(AnimationState){
				case onGround:
					object.frame=0;
					static immutable attackCandidatesOnGround=[attack0,attack1,attack2];
					object.pickRandomAnimation(attackCandidatesOnGround,state);
					break;
				case flying:
					if(sacObject.mustFly)
						goto case onGround; // (bug in original engine: it fails to do this.)
					object.frame=0;
					object.animationState=flyAttack;
					break;
				case tumbling:
					assert(0);
			}
			break;
		case CreatureMode.stunned:
			final switch(object.creatureState.movement){
				case CreatureMovement.onGround:
					object.frame=0;
					object.animationState=sacObject.hasKnockdown?AnimationState.knocked2Floor
						:sacObject.hasGetUp?AnimationState.getUp:AnimationState.stance1;
					break;
				case CreatureMovement.flying:
					object.frame=0;
					assert(sacObject.canFly);
					object.animationState=sacObject.hasFlyDamage?AnimationState.flyDamage:AnimationState.hover;
					break;
				case CreatureMovement.tumbling:
					if(object.animationState!=AnimationState.knocked2Floor){
						object.frame=0;
						object.animationState=AnimationState.stance1;
						bool hasFalling=sacObject.hasFalling;
						if(hasFalling&&object.creatureState.fallingVelocity.xy==Vector2f(0.0f,0.0f)) object.animationState=AnimationState.falling;
						else if(sacObject.canTumble) object.animationState=AnimationState.tumble;
						else if(hasFalling) object.animationState=AnimationState.falling;
					}
					break;
			}
			break;
		case CreatureMode.cower:
			object.frame=0;
			object.animationState=sacObject.hasAnimationState(AnimationState.cower)?AnimationState.cower:AnimationState.idle1;
			if(!state.uniform(5)){ // TODO: figure out the original rule for this
				playSoundTypeAt(sacObject,object.id,SoundType.cower,state);
				object.animationState=sacObject.hasAnimationState(AnimationState.talkCower)?AnimationState.talkCower:AnimationState.idle1;
			}
			break;
		case CreatureMode.casting,CreatureMode.stationaryCasting,CreatureMode.castingMoving:
			object.frame=0;
			object.animationState=object.creatureState.mode==CreatureMode.castingMoving?AnimationState.runSpellcastStart:AnimationState.spellcastStart;
			break;
	}
}

void pickRandomAnimation(B)(ref MovingObject!B object,immutable(AnimationState)[] candidates,ObjectState!B state){
	auto filtered=candidates.filter!(x=>object.sacObject.hasAnimationState(x));
	int len=cast(int)filtered.walkLength;
	assert(!!len&&object.frame==0);
	object.animationState=filtered.drop(state.uniform(len)).front;
}

bool pickNextAnimation(B)(ref MovingObject!B object,immutable(AnimationState)[] sequence,ObjectState!B state){
	auto filtered=sequence.filter!(x=>object.sacObject.hasAnimationState(x)).find!(x=>x==object.animationState);
	if(filtered.empty) return false;
	filtered.popFront();
	if(filtered.empty) return false;
	object.animationState=filtered.front;
	return true;
}

void startIdling(B)(ref MovingObject!B object, ObjectState!B state){
	if(!object.creatureState.mode.among(CreatureMode.moving,CreatureMode.spawning,CreatureMode.reviving,CreatureMode.fastReviving,CreatureMode.takeoff,CreatureMode.landing,CreatureMode.meleeMoving,CreatureMode.meleeAttacking,CreatureMode.stunned,CreatureMode.casting,CreatureMode.stationaryCasting,CreatureMode.castingMoving))
		return;
	object.creatureState.mode=CreatureMode.idle;
	object.setCreatureState(state);
}

void kill(B)(ref MovingObject!B object, ObjectState!B state){
	if(object.creatureStats.flags&Flags.cannotDestroyKill) return;
	with(CreatureMode) if(object.creatureState.mode.among(dying,dead,dissolving,reviving,fastReviving)) return;
	if(!object.sacObject.canDie()) return;
	object.unselect(state);
	object.removeFromGroups(state);
	object.health=0.0f;
	object.creatureState.mode=CreatureMode.dying;
	playSoundTypeAt(object.sacObject,object.id,SoundType.death,state);
	object.setCreatureState(state);
}

enum dissolutionTime=cast(int)(2.5f*updateFPS);
enum dissolutionDelay=updateFPS;
void startDissolving(B)(ref MovingObject!B object,ObjectState!B state){
	if(!object.creatureState.mode.among(CreatureMode.dead,CreatureMode.dissolving)||object.soulId) return;
	object.creatureState.mode=CreatureMode.dissolving;
	object.setCreatureState(state);
}

void destroy(B)(ref Building!B building, ObjectState!B state){
	if(building.flags&Flags.cannotDestroyKill) return;
	if(building.maxHealth(state)==0.0f) return;
	int newLength=0;
	foreach(i,id;building.componentIds.data){
		state.removeLater(id);
		auto destroyed=building.bldg.components[i].destroyed;
		if(destroyed!="\0\0\0\0"){
			auto destObj=SacObject!B.getBLDG(destroyed);
			state.staticObjectById!((ref StaticObject!B object){
				building.componentIds[newLength++]=state.addObject(StaticObject!B(destObj,building.id,object.position,object.rotation));
			})(id);
		}
		state.staticObjectById!((ref StaticObject!B object,state){
			destructionAnimation(object.center,state);
		})(id,state);
	}
	building.componentIds.length=newLength;
	if(building.base){
		state.buildingById!freeManafount(building.base,state);
	}
	if(newLength==0)
		state.removeLater(building.id);
}

void spawnSoul(B)(ref MovingObject!B object, ObjectState!B state){
	with(CreatureMode) if(object.creatureState.mode!=CreatureMode.dead||object.soulId!=0) return;
	int numSouls=object.sacObject.numSouls;
	if(!numSouls) return;
	object.soulId=state.addObject(Soul!B(object.id,object.side,object.sacObject.numSouls,object.soulPosition,SoulState.emerging));
}

void createSoul(B)(ref MovingObject!B object, ObjectState!B state){
	with(CreatureMode) if(object.creatureState.mode!=CreatureMode.dead||object.soulId!=0) return;
	int numSouls=object.sacObject.numSouls;
	if(!numSouls) return;
	object.soulId=state.addObject(Soul!B(object.id,object.side,object.sacObject.numSouls,object.soulPosition,SoulState.normal));
}

int spawn(T=Creature,B)(ref MovingObject!B caster,char[4] tag,int flags,ObjectState!B state,bool pre){
	auto curObj=SacObject!B.getSAXS!T(tag);
	auto position=caster.position;
	auto mode=pre?CreatureMode.preSpawning:CreatureMode.spawning;
	auto movement=CreatureMovement.flying;
	auto facing=caster.creatureState.facing;
	auto newPosition=position+rotate(facingQuaternion(facing),Vector3f(0.0f,6.0f,0.0f));
	if(!state.isOnGround(position)||state.isOnGround(newPosition)) position=newPosition; // TODO: find closet ground to newPosition instead
	position.z=state.getHeight(position);
	auto creatureState=CreatureState(mode, movement, facing);
	auto rotation=facingQuaternion(facing);
	auto obj=MovingObject!B(curObj,position,rotation,AnimationState.disoriented,0,creatureState,curObj.creatureStats(flags),caster.side);
	obj.setCreatureState(state);
	obj.updateCreaturePosition(state);
	auto ord=Order(CommandType.retreat,OrderTarget(TargetType.creature,caster.id,caster.position));
	obj.order(ord,state,caster.side);
	return state.addObject(obj);
}
int spawn(T=Creature,B)(int casterId,char[4] tag,int flags,ObjectState!B state,bool pre=true){
	return state.movingObjectById!(.spawn,function int(){ assert(0); })(casterId,tag,flags,state,pre);
}

int makeBuilding(B)(ref MovingObject!B caster,char[4] tag,int flags,int base,ObjectState!B state,bool pre=true)in{
	assert(base>0);
}do{
	auto data=tag in bldgs;
	enforce(!!data&&!(data.flags&BldgFlags.ground));
	auto position=state.buildingById!(
		(bldg,state)=>state.staticObjectById!(
			(obj)=>obj.position,
			function Vector3f(){ assert(0); })(bldg.componentIds[0]),
		function Vector3f(){ assert(0); })(base,state);
	float facing=0.0f; // TODO: ok?
	auto buildingId=state.addObject(Building!B(data,caster.side,flags,facing));
	state.buildingById!((ref Building!B building){
		if(flags&Flags.damaged) building.health/=10.0f;
		if(flags&Flags.destroyed) building.health=0.0f;
		foreach(ref component;data.components){
			auto curObj=SacObject!B.getBLDG(flags&Flags.destroyed&&component.destroyed!="\0\0\0\0"?component.destroyed:component.tag);
			auto offset=Vector3f(component.x,component.y,component.z);
			offset=rotate(facingQuaternion(building.facing), offset);
			auto cposition=position+offset;
			if(!state.isOnGround(cposition)) continue;
			cposition.z=state.getGroundHeight(cposition);
			float facing=0.0f; // TODO: ok?
			auto rotation=facingQuaternion(2*cast(float)PI/360.0f*(facing+component.facing));
			building.componentIds~=state.addObject(StaticObject!B(curObj,building.id,cposition,rotation));
		}
		if(base) state.buildingById!((ref manafount,state){ putOnManafount(building,manafount,state); })(base,state);
	})(buildingId);
	return buildingId;
}
int makeBuilding(B)(int casterId,char[4] tag,int flags,int base,ObjectState!B state,bool pre=true)in{
	assert(base>0);
}do{
	return state.movingObjectById!(.makeBuilding,function int(){ assert(0); })(casterId,tag,flags,base,state,pre);
}

bool canStun(B)(ref MovingObject!B object,ObjectState!B state){
	final switch(object.creatureState.mode) with(CreatureMode){
		case idle,moving,takeoff,landing,meleeMoving,meleeAttacking,cower,casting,stationaryCasting,castingMoving: return true;
		case dying,dead,dissolving,preSpawning,spawning,reviving,fastReviving,stunned: return false;
	}
}

void stun(B)(ref MovingObject!B object, ObjectState!B state){
	if(!object.canStun(state)) return;
	object.creatureState.mode=CreatureMode.stunned;
	object.setCreatureState(state);
}
void damageStun(B)(ref MovingObject!B object, Vector3f attackDirection, ObjectState!B state){
	if(!object.canStun(state)) return;
	object.creatureState.mode=CreatureMode.stunned;
	object.setCreatureState(state);
	object.damageAnimation(attackDirection,state,false);
}

void catapult(B)(ref MovingObject!B object, Vector3f velocity, ObjectState!B state){
	with(CreatureMode) if(object.creatureState.mode.among(dead,dissolving)) return;
	if(object.creatureState.movement==CreatureMovement.flying) return;
	if(object.creatureState.mode!=CreatureMode.dying)
		object.creatureState.mode=CreatureMode.stunned;
	// TODO: in original engine, stunned creatures don't switch to the tumbling animation
	object.creatureState.movement=CreatureMovement.tumbling;
	object.creatureState.fallingVelocity=velocity;
	object.setCreatureState(state);
}

void immediateRevive(B)(ref MovingObject!B object,ObjectState!B state){
	with(CreatureMode) if(!object.creatureState.mode.among(dying,dead)) return;
	if(object.soulId!=0){
		state.removeObject(object.soulId);
		object.soulId=0;
	}
	object.health=object.creatureStats.maxHealth;
	object.creatureState.mode=CreatureMode.idle;
	object.setCreatureState(state);
}

void fastRevive(B)(ref MovingObject!B object,ObjectState!B state){
	object.revive(state,true);
}

void revive(B)(ref MovingObject!B object,ObjectState!B state,bool fast=false){
	with(CreatureMode) if(object.creatureState.mode!=dead) return;
	if(object.soulId==0) return;
	if(!state.soulById!((ref Soul!B s){
		if(s.state.among(SoulState.normal,SoulState.emerging)){
			s.state=SoulState.reviving;
			return true;
		}
		return false;
	},()=>false)(object.soulId))
		return;
	object.health=object.creatureStats.maxHealth;
	object.creatureState.mode=fast?CreatureMode.fastReviving:CreatureMode.reviving;
	object.setCreatureState(state);
}

void startFlying(B)(ref MovingObject!B object,ObjectState!B state){
	with(CreatureMode){
		if(object.creatureState.mode==landing){
			object.startIdling(state);
			return;
		}
		if(!object.sacObject.canFly||!object.creatureState.mode.among(idle,moving)||
		   object.creatureState.movement!=CreatureMovement.onGround)
			return;
	}
	object.creatureState.mode=CreatureMode.takeoff;
	object.setCreatureState(state);
}

void land(B)(ref MovingObject!B object,ObjectState!B state){
	with(CreatureMode)
		if(object.sacObject.mustFly||!object.creatureState.mode.among(idle,moving)||
		   object.creatureState.movement!=CreatureMovement.flying)
			return;
	if(!state.isOnGround(object.position))
		return;
	object.creatureState.mode=CreatureMode.landing;
	object.setCreatureState(state);
}

void startMeleeAttacking(B)(ref MovingObject!B object,ObjectState!B state){
	with(CreatureMode) with(CreatureMovement)
		if(!object.creatureState.mode.among(idle,moving)||
		   !object.creatureState.movement.among(onGround,flying)||
		   !object.sacObject.canAttack)
			return;
	object.creatureState.mode=CreatureMode.meleeMoving;
	object.setCreatureState(state);
}


enum DamageDirection{
	front,
	right,
	back,
	left,
	top
}
DamageDirection getDamageDirection(B)(ref MovingObject!B object,Vector3f attackDirection,ObjectState!B state){
	auto fromFront=rotate(object.rotation,Vector3f(0.0f,-1.0f,0.0f));
	auto fromRight=rotate(object.rotation,Vector3f(-1.0f,0.0f,0.0f));
	auto fromBack=rotate(object.rotation,Vector3f(0.0f,1.0f,0.0f));
	auto fromLeft=rotate(object.rotation,Vector3f(1.0f,0.0f,0.0f));
	auto fromTop=rotate(object.rotation,Vector3f(0.0f,0.0f,-1.0f));
	auto best=dot(fromFront,attackDirection),bestDirection=DamageDirection.front;
	foreach(i,alias dir;Seq!(fromRight,fromBack,fromLeft,fromTop)){
		auto cand=dot(dir,attackDirection);
		if(best<cand){
			best=cand;
			bestDirection=cast(DamageDirection)(i+1);
		}
	}
	return bestDirection;
}

void damageAnimation(B)(ref MovingObject!B object,Vector3f attackDirection,ObjectState!B state,bool checkIdle=true){
	playSoundTypeAt(object.sacObject,object.id,SoundType.damaged,state);
	if(checkIdle&&object.creatureState.mode!=CreatureMode.idle||!checkIdle&&object.creatureState.mode!=CreatureMode.stunned) return;
	final switch(object.creatureState.movement){
		case CreatureMovement.onGround:
			break;
		case CreatureMovement.flying:
			object.animationState=AnimationState.flyDamage;
			object.frame=0;
			return;
		case CreatureMovement.tumbling:
			return;
	}
	if(object.creatureState.movement==CreatureMovement.tumbling) return;
	auto damageDirection=getDamageDirection(object,attackDirection,state);
	auto animationState=cast(AnimationState)(AnimationState.damageFront+damageDirection);
	if(!object.sacObject.hasAnimationState(animationState))
		animationState=animationState.stance1;
	object.animationState=animationState;
	object.frame=0;
}

bool canDamage(B)(ref MovingObject!B object,ObjectState!B state){
	if(object.creatureStats.flags&Flags.cannotDamage) return false;
	final switch(object.creatureState.mode) with(CreatureMode){
		case idle,moving,takeoff,landing,meleeMoving,meleeAttacking,stunned,cower,casting,stationaryCasting,castingMoving: return true;
		case dying,dead,dissolving,preSpawning,spawning,reviving,fastReviving: return false;
	}
}

void dealDamage(B)(ref MovingObject!B object,float damage,ref MovingObject!B attacker,ObjectState!B state){
	if(!object.canDamage(state)) return;
	auto actualDamage=min(object.health,damage*state.sideDamageMultiplier(attacker.side,object.side));
	object.health=object.health-actualDamage;
	if(object.creatureStats.flags&Flags.cannotDestroyKill)
		object.health=max(object.health,1.0f);
	// TODO: give xp to attacker
	if(object.health==0.0f)
		object.kill(state);
	attacker.heal(damage*attacker.creatureStats.drain,state);
}

bool canDamage(B)(ref Building!B building,ObjectState!B state){
	if(building.flags&Flags.cannotDamage) return false;
	if(building.health==0.0f) return false;
	return true;
}

void dealDamage(B)(ref Building!B building,float damage,ref MovingObject!B attacker,ObjectState!B state){
	if(!building.canDamage(state)) return;
	auto actualDamage=min(building.health,damage*state.sideDamageMultiplier(attacker.side,building.side));
	building.health-=actualDamage;
	if(building.flags&Flags.cannotDestroyKill)
		building.health=max(building.health,1.0f);
	// TODO: give xp to attacker
	if(building.health==0.0f)
		building.destroy(state);
}

void heal(B)(ref MovingObject!B object,float amount,ObjectState!B state){
	object.health=min(object.health+amount,object.creatureStats.maxHealth);
}
void heal(B)(ref Building!B building,float amount,ObjectState!B state){
	building.health=min(building.health+amount,building.maxHealth(state));
}
void giveMana(B)(ref MovingObject!B object,float amount,ObjectState!B state){
	object.creatureStats.mana=min(object.creatureStats.mana+amount,object.creatureStats.maxMana);
}

float meleeDistance(Vector3f[2] objectHitbox,Vector3f attackerCenter){
	return closestBoxFaceNormalWithProjectionLength(objectHitbox,attackerCenter)[1];
}

void dealMeleeDamage(B)(ref MovingObject!B object,ref MovingObject!B attacker,ObjectState!B state){
	auto damage=attacker.meleeStrength/attacker.numAttackTicks(attacker.animationState); // TODO: figure this out
	auto objectHitbox=object.hitbox;
	auto attackerHitbox=attacker.meleeHitbox, attackerCenter=boxCenter(attackerHitbox), attackerSize=0.5f*boxSize(attackerHitbox);
	auto normalProjectionLength=closestBoxFaceNormalWithProjectionLength(objectHitbox,attackerCenter);
	auto normal=normalProjectionLength[0], distance=max(0.0f,normalProjectionLength[1]);
	auto damageMultiplier=max(0.0f,1.0f-max(0.0f,distance/abs(dot(attackerSize,normal))));
	auto actualDamage=damageMultiplier*damage*object.creatureStats.meleeResistance;
	auto attackDirection=object.center-attacker.center; // TODO: good?
	auto stunBehavior=attacker.stunBehavior;
	auto direction=getDamageDirection(object,attackDirection,state);
	bool fromBehind=direction==DamageDirection.back;
	bool fromSide=!!direction.among(DamageDirection.left,DamageDirection.right);
	if(fromBehind) actualDamage*=2.0f;
	else if(fromSide) actualDamage*=1.5f;
	object.dealDamage(actualDamage,attacker,state);
	if(stunBehavior==StunBehavior.always || fromBehind && stunBehavior==StunBehavior.fromBehind){
		if(actualDamage>=0.5f*damage){
			playSoundTypeAt(attacker.sacObject,attacker.id,SoundType.stun,state);
			object.damageStun(attackDirection,state);
			return;
		}
	}
	object.damageAnimation(attackDirection,state);
	final switch(object.stunnedBehavior){
		case StunnedBehavior.normal:
			break;
		case StunnedBehavior.onMeleeDamage,StunnedBehavior.onDamage:
			playSoundTypeAt(attacker.sacObject,attacker.id,SoundType.stun,state);
			object.damageStun(attackDirection,state);
			return;
	}
	playSoundTypeAt(attacker.sacObject,attacker.id,SoundType.hit,state);
}

void dealMeleeDamage(B)(ref Building!B building,ref MovingObject!B attacker,ObjectState!B state){
	auto damage=attacker.meleeStrength;
	auto actualDamage=damage*building.meleeResistance*attacker.sacObject.buildingMeleeDamageMultiplier/attacker.numAttackTicks(attacker.animationState);
	building.dealDamage(actualDamage,attacker,state);
	playSoundTypeAt(attacker.sacObject,attacker.id,SoundType.hitWall,state);
}


void setMovement(B)(ref MovingObject!B object,MovementDirection direction,ObjectState!B state,int side=-1){
	if(!object.canOrder(side,state)) return;
	if(object.creatureState.movement==CreatureMovement.flying &&
	   direction==MovementDirection.backward &&
	   !object.sacObject.canFlyBackward)
		return;
	if(object.creatureState.movementDirection==direction)
		return;
	object.creatureState.movementDirection=direction;
	if(direction==MovementDirection.none) object.creatureState.speedLimit=float.infinity;
	if(object.creatureState.mode.among(CreatureMode.idle,CreatureMode.moving))
		object.setCreatureState(state);
}
void stopMovement(B)(ref MovingObject!B object,ObjectState!B state,int side=-1){
	object.setMovement(MovementDirection.none,state,side);
}
void startMovingForward(B)(ref MovingObject!B object,ObjectState!B state,int side=-1){
	object.setMovement(MovementDirection.forward,state,side);
}
void startMovingBackward(B)(ref MovingObject!B object,ObjectState!B state,int side=-1){
	object.setMovement(MovementDirection.backward,state,side);
}

void setTurning(B)(ref MovingObject!B object,RotationDirection direction,ObjectState!B state,int side=-1){
	if(!object.canOrder(side,state)) return;
	object.creatureState.rotationDirection=direction;
	if(direction==RotationDirection.none) object.creatureState.rotationSpeedLimit=float.infinity;
}
void stopTurning(B)(ref MovingObject!B object,ObjectState!B state,int side=-1){
	object.setTurning(RotationDirection.none,state,side);
}
void startTurningLeft(B)(ref MovingObject!B object,ObjectState!B state,int side=-1){
	object.setTurning(RotationDirection.left,state,side);
}
void startTurningRight(B)(ref MovingObject!B object,ObjectState!B state,int side=-1){
	object.setTurning(RotationDirection.right,state,side);
}

void startCowering(B)(ref MovingObject!B object,ObjectState!B state){
	if(!object.isPeasant) return;
	object.stopMovement(state);
	object.creatureState.mode=CreatureMode.cower;
	object.setCreatureState(state);
}

bool startCasting(B)(ref MovingObject!B object,int numFrames,bool stationary,ObjectState!B state){
	if(!object.isWizard) return false;
	if(!object.creatureState.mode.among(CreatureMode.idle,CreatureMode.moving)) return false;
	if(stationary) object.creatureState.mode=CreatureMode.stationaryCasting;
	else object.creatureState.mode=object.creatureState.mode==CreatureMode.idle?CreatureMode.casting:CreatureMode.castingMoving;
	object.creatureState.timer=numFrames;
	object.creatureState.timer2=playSoundTypeAt!true(object.sacObject,object.id,SoundType.incantation,state)+updateFPS/10;
	object.setCreatureState(state);
	return true;
}
int getCastingTime(B)(ref MovingObject!B object,int numFrames,bool stationary,ObjectState!B state){
	// TODO: "stationary" parameter is probably unnecessary
	auto sacObject=object.sacObject;
	auto start=sacObject.numFrames(stationary?AnimationState.spellcastStart:AnimationState.runSpellcastStart)*updateAnimFactor;
	auto mid=sacObject.numFrames(stationary?AnimationState.spellcast:AnimationState.runSpellcast)*updateAnimFactor;
	auto end=sacObject.numFrames(stationary?AnimationState.spellcastEnd:AnimationState.runSpellcastEnd)*updateAnimFactor;
	auto castingTime=sacObject.castingTime(stationary?AnimationState.spellcastEnd:AnimationState.runSpellcastEnd)*updateAnimFactor;
	return start+max(0,(numFrames-start-end+mid-1))/mid*mid+castingTime;
}

bool speedUp(B)(ref MovingObject!B object,SacSpell!B spell,ObjectState!B state){
	playSoundAt("pups",object.id,state,2.0f);
	object.creatureStats.effects.speedUp+=1;
	auto duration=object.isWizard?spell.duration*0.2f:spell.duration*1000.0f/object.creatureStats.maxHealth;
	state.addEffect(SpeedUp!B(object.id,cast(int)(duration*updateFPS)));
	return true;
}
bool speedUp(B)(int creature,SacSpell!B spell,ObjectState!B state){
	if(!state.isValidId(creature,TargetType.creature)) return false;
	return state.movingObjectById!(speedUp,()=>false)(creature,spell,state);
}

enum summonSoundGain=2.0f;
bool startCasting(B)(ref MovingObject!B object,SacSpell!B spell,Target target,ObjectState!B state){
	auto wizard=state.getWizard(object.id);
	if(!wizard) return false;
	if(state.spellStatus!false(wizard,spell,target)!=SpellStatus.ready) return false;
	int numFrames=cast(int)ceil(updateFPS*spell.castingTime(wizard.level));
	if(!object.startCasting(numFrames,spell.stationary,state))
		return false;
	// TODO: "stationary" parameter necessary? If so, check what original engine does if wizard walks and stops
	auto castingTime=object.getCastingTime(numFrames,spell.stationary,state);
	auto manaCostPerFrame=spell.manaCost/castingTime;
	auto manaDrain=ManaDrain!B(object.id,manaCostPerFrame);
	(*wizard).applyCooldown(spell,state);
	bool stun(){
		object.damageStun(Vector3f(0.0f,0.0f,-1.0f),state);
		return false;
	}
	final switch(spell.type){
		case SpellType.creature:
			assert(target==Target.init);
			auto creature=spawn(object.id,spell.tag,0,state);
			state.setRenderMode!(MovingObject!B,RenderMode.transparent)(creature);
			playSoundAt("NMUS",creature,state,summonSoundGain);
			state.addEffect(CreatureCasting!B(manaDrain,spell,creature));
			return true;
		case SpellType.spell:
			bool ok=false;
			switch(spell.tag){
				case "pups":
					ok=target.id==object.id?speedUp(object,spell,state):speedUp(target.id,spell,state);
					goto default;
				// TODO
				default:
					if(ok) state.addEffect(manaDrain);
					else stun();
					return ok;
			}
		case SpellType.structure:
			if(!spell.isBuilding) goto case SpellType.spell;
			auto base=state.staticObjectById!((obj)=>obj.buildingId,()=>0)(target.id);
			if(base){ // TODO: stun both wizards on simultaneous lith cast
				auto god=state.getCurrentGod(wizard);
				if(god==God.none) god=God.persephone;
				auto building=makeBuilding(object.id,spell.buildingTag(god),AdditionalBuildingFlags.inactive|Flags.cannotDamage,base,state);
				state.setRenderMode!(Building!B,RenderMode.transparent)(building);
				float buildingHeight=state.buildingById!((bldg,state)=>height(bldg,state),()=>0.0f)(building,state);
				state.addEffect(StructureCasting!B(manaDrain,spell,building,buildingHeight,castingTime,0));
				return true;
			}else return stun();
	}
}

bool face(B)(ref MovingObject!B object,float facing,ObjectState!B state){
	auto angle=facing-object.creatureState.facing;
	while(angle<-cast(float)PI) angle+=2*cast(float)PI;
	while(angle>cast(float)PI) angle-=2*cast(float)PI;
	enum threshold=1e-3;
	object.creatureState.rotationSpeedLimit=rotationSpeedLimitFactor*abs(angle);
	if(angle>threshold) object.startTurningLeft(state);
	else if(angle<-threshold) object.startTurningRight(state);
	else{
		object.stopTurning(state);
		return true;
	}
	return false;
}

float facingTowards(B)(ref MovingObject!B object,Vector3f position,ObjectState!B state){
	auto direction=position.xy-object.position.xy;
	return atan2(-direction.x,direction.y);
}

void turnToFaceTowards(B)(ref MovingObject!B object,Vector3f position,ObjectState!B state){
	object.face(object.facingTowards(position,state),state);
}

void setPitching(B)(ref MovingObject!B object,PitchingDirection direction,ObjectState!B state,int side=-1){
	if(!object.canOrder(side,state)) return;
	if(!object.sacObject.canFly||object.creatureState.movement!=CreatureMovement.flying) return;
	object.creatureState.pitchingDirection=direction;
	if(direction==PitchingDirection.none) object.creatureState.pitchingSpeedLimit=float.infinity;
}
void stopPitching(B)(ref MovingObject!B object,ObjectState!B state,int side=-1){
	object.setPitching(PitchingDirection.none,state,side);
}
void startPitchingUp(B)(ref MovingObject!B object,ObjectState!B state,int side=-1){
	object.setPitching(PitchingDirection.up,state,side);
}
void startPitchingDown(B)(ref MovingObject!B object,ObjectState!B state,int side=-1){
	object.setPitching(PitchingDirection.down,state,side);
}

bool pitch(B)(ref MovingObject!B object,float pitch_,ObjectState!B state){
	auto angle=pitch_-object.creatureState.flyingPitch;
	while(angle<-cast(float)PI) angle+=2*cast(float)PI;
	while(angle>cast(float)PI) angle-=2*cast(float)PI;
	enum threshold=1e-3;
	object.creatureState.pitchingSpeedLimit=rotationSpeedLimitFactor*abs(angle);
	if(angle>threshold) object.startPitchingUp(state);
	else if(angle<-threshold) object.startPitchingDown(state);
	else{
		object.stopPitching(state);
		return true;
	}
	return false;
}

void pitchToFaceTowards(B)(ref MovingObject!B object,Vector3f position,ObjectState!B state){
	auto direction=position-object.position;
	if(object.creatureState.targetFlyingHeight!is float.nan)
		direction.z+=object.creatureState.targetFlyingHeight;
	auto distance=direction.xy.length;
	auto pitch_=atan2(direction.z,distance);
	object.pitch(pitch_,state);
}

bool movingForwardGetsCloserTo(B)(ref MovingObject!B object,Vector3f position,float speed,ObjectState!B state,bool* slowDown=null){
	auto direction=position.xy-object.position.xy;
	auto facing=object.creatureState.facing;
	auto rotationSpeed=object.creatureStats.rotationSpeed(object.creatureState.movement==CreatureMovement.flying)/updateFPS;
	auto forward=Vector2f(-sin(facing),cos(facing));
	auto angle=atan2(-direction.x,direction.y);
	angle-=object.creatureState.facing;
	while(angle<-cast(float)PI) angle+=2*cast(float)PI;
	while(angle>cast(float)PI) angle-=2*cast(float)PI;
	if(dot(direction,forward)<0.0f){
		if(object.creatureState.movement!=CreatureMovement.flying)
			return false;
		if(slowDown) *slowDown=true;
	}
	float r=speed/rotationSpeed,distsqr=direction.lengthsqr;
	if(distsqr>=2.2f*r^^2) return true;
	if(abs(angle)<acos(1.0f-distsqr/(2.2f*r^^2))) return true;
	auto limit=rotationSpeedLimitFactor*abs(angle);
	return limit<1e-3;
}

void order(B)(ref MovingObject!B object,Order order,ObjectState!B state,int side=-1){
	if(!object.canOrder(side,state)) return;
	object.creatureAI.order=order;
}

void clearOrder(B)(ref MovingObject!B object,ObjectState!B state){
	object.creatureAI.order=Order.init;
	object.stopMovement(state);
	if(object.creatureState.movement==CreatureMovement.flying)
		object.creatureState.speedLimit=0.0f;
	object.stopTurning(state);
	object.stopPitching(state);
}

bool hasOrders(B)(ref MovingObject!B object,ObjectState!B state){
	return object.creatureAI.order.command!=CommandType.none;
}

bool turnToFaceTowardsEvading(B)(ref MovingObject!B object,Vector3f targetPosition,ObjectState!B state){
	auto hitbox=object.hitbox;
	auto rotation=facingQuaternion(object.creatureState.facing);
	auto distance=0.05f*((hitbox[1].x-hitbox[0].x)+(hitbox[1].y-hitbox[0].y)); // TODO: improve
	auto frontHitbox=moveBox(hitbox,rotate(rotation,distance*Vector3f(0.0f,1.0f,0.0f)));
	auto frontObstacleFrontObstacleHitbox=collisionTargetWithHitbox(object.id,hitbox,frontHitbox,state);
	auto frontObstacle=frontObstacleFrontObstacleHitbox[0];
	if(frontObstacle){
		auto frontObstacleHitbox=frontObstacleFrontObstacleHitbox[1];
		Vector2f[2] frontObstacleHitbox2d=[frontObstacleHitbox[0].xy,frontObstacleHitbox[1].xy];
		auto frontObstacleDirection=-closestBoxFaceNormal(frontObstacleHitbox2d,object.position.xy);
		auto facing=object.creatureState.facing;
		auto evasion=dot(Vector2f(cos(facing),sin(facing)),frontObstacleDirection)<=0.0f?RotationDirection.right:RotationDirection.left;
		object.setTurning(evasion,state);
		object.startMovingForward(state);
		return true;
	}
	object.turnToFaceTowards(targetPosition,state);
	auto rotationDirection=object.creatureState.rotationDirection;
	if(rotationDirection!=RotationDirection.none){
		enum sideHitboxFactor=1.1f;
		auto sideOffsetX=rotationDirection==RotationDirection.right?1.0f:-1.0f;
		auto sideHitbox=moveBox(scaleBox(hitbox,sideHitboxFactor),rotate(rotation,distance*Vector3f(sideOffsetX,0.0f,0.0f)));
		bool blockedSide=!!collisionTarget(object.id,hitbox,sideHitbox,state);
		if(blockedSide){
			object.stopTurning(state);
			object.startMovingForward(state);
			return true;
		}
	}
	return false;
}

bool stop(B)(ref MovingObject!B object,float targetFacing,ObjectState!B state){
	object.stopMovement(state);
	if(object.creatureState.movement==CreatureMovement.flying) object.creatureState.speedLimit=0.0f;
	auto facingFinished=targetFacing is float.init||object.face(targetFacing,state);
	auto pitchingFinished=true;
	if(object.creatureState.movement==CreatureMovement.flying){
		pitchingFinished=object.pitch(0.0f,state);
		object.creatureState.targetFlyingHeight=0.0f;
	}
	return !(facingFinished && pitchingFinished);
}

bool stopAndFaceTowards(B)(ref MovingObject!B object,Vector3f position,ObjectState!B state){
	return object.stop(object.facingTowards(position,state),state);
}

void moveTowards(B)(ref MovingObject!B object,Vector3f targetPosition,ObjectState!B state,bool evade=true){
	auto speed=object.speed(state)/updateFPS;
	auto distancesqr=(object.position.xy-targetPosition.xy).lengthsqr;
	if(object.creatureState.movement==CreatureMovement.flying){
		if(distancesqr>(0.5f*updateFPS*speed)^^2){
			if(object.creatureAI.isColliding) object.startPitchingUp(state);
			else object.pitchToFaceTowards(targetPosition,state);
			auto flyingHeight=object.position.z-state.getHeight(object.position);
			auto minimumFlyingHeight=object.creatureStats.flyingHeight;
			if(flyingHeight<minimumFlyingHeight) object.creatureState.targetFlyingHeight=minimumFlyingHeight;
			else object.creatureState.targetFlyingHeight=float.nan;
		}else{
			object.pitch(0.0f,state);
			object.creatureState.targetFlyingHeight=0.0f;
		}
	}else if(object.creatureState.mode!=CreatureMode.takeoff&&object.sacObject.canFly){
		auto distance=sqrt(distancesqr);
		auto walkingSpeed=object.speedOnGround(state),flyingSpeed=object.speedInAir(state);
		if(object.takeoffTime(state)+distance/flyingSpeed<distance/walkingSpeed)
			object.startFlying(state);
	}
	if(!evade) object.turnToFaceTowards(targetPosition,state);
	else if(object.turnToFaceTowardsEvading(targetPosition,state)) return;
	bool slowDown=false;
	if(object.movingForwardGetsCloserTo(targetPosition,speed,state,&slowDown)){
		object.startMovingForward(state);
		auto distance=speedLimitFactor*(object.position.xy-targetPosition.xy).length;
		if(object.creatureState.movement==CreatureMovement.flying){
			auto slowdownDist=5.0f;
			auto slowdownTime=2.0f*slowdownDist/(speed*updateFPS);
			object.creatureState.speedLimit=min(distance,object.creatureState.speedLimit+speed/(updateFPS*slowdownTime));
			if(distance<slowdownDist){
				auto distanceTraveled=slowdownDist-distance;
				auto currentTime=slowdownTime-sqrt(slowdownTime*(slowdownTime-2.0f*distanceTraveled/(speed*updateFPS)));
				object.creatureState.speedLimit=min(object.creatureState.speedLimit,speed*(1.0f-currentTime/slowdownTime));
			}
		}else object.creatureState.speedLimit=distance;
		if(slowDown) object.creatureState.speedLimit=min(object.creatureState.speedLimit,0.75f*speed);
	}else{
		object.stopMovement(state);
		if(object.creatureState.movement==CreatureMovement.flying)
			object.creatureState.speedLimit=0.0f;
	}
}

bool moveTo(B)(ref MovingObject!B object,Vector3f targetPosition,float targetFacing,ObjectState!B state,bool evade=true){
	auto speed=object.speed(state)/updateFPS;
	auto distancesqr=(object.position.xy-targetPosition.xy).lengthsqr;
	if(distancesqr>(2.0f*speed)^^2){
		object.moveTowards(targetPosition,state,evade);
		return true;
	}
	return object.stop(targetFacing,state);
}

bool retreatTowards(B)(ref MovingObject!B object,Vector3f targetPosition,ObjectState!B state){
	if(object.patrolAround(targetPosition,guardDistance,state))
		return true;
	auto speed=object.speed(state)/updateFPS;
	auto distancesqr=(object.position.xy-targetPosition.xy).lengthsqr;
	if(distancesqr<=(retreatDistance+speed)^^2)
		return object.stopAndFaceTowards(targetPosition,state);
	object.moveTowards(targetPosition,state);
	return true;
}

bool isValidAttackTarget(B,T)(T obj,ObjectState!B state)if(is(T==MovingObject!B)||is(T==StaticObject!B)){
	// this needs to be kept in synch with addToProximity
	return obj.health(state)!=0.0f;
}
bool isValidAttackTarget(B)(int targetId,ObjectState!B state){
	return state.objectById!(.isValidAttackTarget)(targetId,state);
}
bool isValidGuardTarget(B,T)(T obj,ObjectState!B state)if(is(T==MovingObject!B)||is(T==StaticObject!B)){
	static if(is(T==StaticObject!B)) return true;
	return isValidAttackTarget(obj,state); // TODO: dead wizards
}
bool isValidGuardTarget(B)(int targetId,ObjectState!B state){
	return state.objectById!(.isValidGuardTarget)(targetId,state);
}

bool attack(B)(ref MovingObject!B object,int targetId,ObjectState!B state){
	if(!isValidAttackTarget(targetId,state)) return false;
	enum meleeHitboxFactor=0.8f;
	auto meleeHitbox=scaleBox(object.meleeHitbox,meleeHitboxFactor);
	auto meleeHitboxCenter=boxCenter(meleeHitbox);
	static bool intersects(T)(T obj,Vector3f[2] hitbox){
		static if(is(T==MovingObject!B)){
			return boxesIntersect(obj.hitbox,hitbox);
		}else{
			foreach(bhitb;obj.hitboxes)
				if(boxesIntersect(bhitb,hitbox))
					return true;
			return false;
		}
	}
	int target=0;
	if(state.objectById!intersects(targetId,meleeHitbox)){
		target=meleeAttackTarget(object,state); // TODO: share melee hitbox computation?
		if(target&&target!=targetId&&!state.objectById!((obj,side,state)=>state.sides.getStance(side,.side(obj,state))==Stance.enemy)(target,object.side,state))
			target=0;
	}
	auto targetPosition=state.objectById!((obj,meleeHitboxCenter)=>boxCenter(obj.closestHitbox(meleeHitboxCenter)))(targetId,meleeHitboxCenter);
	auto meleeHitboxOffset=meleeHitboxCenter-object.position;
	auto movementPosition=targetPosition-meleeHitboxOffset;
	auto meleeHitboxOffsetXY=0.75f*(targetPosition.xy-object.position.xy).normalized*meleeHitboxOffset.xy.length;
	meleeHitboxOffset.x=meleeHitboxOffsetXY.x, meleeHitboxOffset.y=meleeHitboxOffsetXY.y;
	if(target||!object.moveTo(movementPosition,float.init,state,!object.isMeleeAttacking(state))){
		object.pitch(0.0f,state);
		object.turnToFaceTowards(targetPosition,state);
		enum normalHitboxFactor=1.01f;
		if(state.objectById!intersects(targetId,scaleBox(object.hitbox,normalHitboxFactor)))
			object.stopMovement(state);
	}
	if(target){
		object.startMeleeAttacking(state);
		if(object.creatureState.movement==CreatureMovement.flying)
			object.creatureState.targetFlyingHeight=movementPosition.z-state.getHeight(object.position);
	}
	return true;
}

bool patrolAround(B)(ref MovingObject!B object,Vector3f position,float range,ObjectState!B state){
	if(!object.isAggressive(state)) return false;
	auto targetId=state.proximity.closestEnemyInRange(object.side,position,range,EnemyType.all,state);
	if(targetId)
		if(object.attack(targetId,state))
			return true;
	return false;
}

bool guard(B)(ref MovingObject!B object,int targetId,ObjectState!B state){
	if(!isValidGuardTarget(targetId,state)) return false;
	auto targetPositionTargetFacingTargetSpeedTargetMode=state.movingObjectById!((obj,state)=>tuple(obj.position,obj.creatureState.facing,obj.speed(state)/updateFPS,obj.creatureState.mode), ()=>tuple(object.creatureAI.order.target.position,object.creatureAI.order.targetFacing,0.0f,CreatureMode.idle))(targetId,state);
	auto targetPosition=targetPositionTargetFacingTargetSpeedTargetMode[0], targetFacing=targetPositionTargetFacingTargetSpeedTargetMode[1], targetSpeed=targetPositionTargetFacingTargetSpeedTargetMode[2],targetMode=targetPositionTargetFacingTargetSpeedTargetMode[3];
	object.creatureAI.order.target.position=targetPosition;
	object.creatureAI.order.targetFacing=targetFacing;
	auto formationOffset=object.creatureAI.order.formationOffset;
	targetPosition=getTargetPosition(targetPosition,targetFacing,formationOffset,state);
	if(!object.patrolAround(targetPosition,guardDistance,state)) // TODO: prefer enemies that attack the guard target?
		object.moveTo(targetPosition,targetFacing,state);
	if((object.position-targetPosition).lengthsqr<=(0.1f*updateFPS*targetSpeed)^^2)
		object.creatureState.speedLimit=min(object.creatureState.speedLimit,targetSpeed);
	return true;
}

bool patrol(B)(ref MovingObject!B object,ObjectState!B state){
	if(!object.isAggressive(state)) return false;
	auto position=object.position;
	auto range=object.aggressiveRange(CommandType.none,state);
	auto targetId=state.proximity.closestEnemyInRange(object.side,position,range,EnemyType.all,state);
	if(targetId)
		if(object.attack(targetId,state))
			return true;
	return false;
}

bool advance(B)(ref MovingObject!B object,Vector3f targetPosition,ObjectState!B state){
	if(!object.isAggressive(state)) return false;
	auto position=object.position;
	auto range=object.advanceRange(CommandType.none,state);
	auto targetId=state.proximity.closestEnemyInRangeAndClosestToPreferringAttackersOf(object.side,object.position,range,targetPosition,object.id,EnemyType.all,state);
	if(targetId)
		if(object.attack(targetId,state))
			return true;
	return false;
}

enum retreatDistance=9.0f;
enum guardDistance=18.0f; // ok?
enum attackDistance=100.0f; // ok?
enum shelterDistance=50.0f;
enum scareDistance=50.0f;
enum speedLimitFactor=0.5f;
enum rotationSpeedLimitFactor=1.0f;

bool requiresAI(CreatureMode mode){
	with(CreatureMode) final switch(mode){
		case idle,moving,takeoff,landing,meleeMoving,meleeAttacking,casting,stationaryCasting,castingMoving: return true;
		case dying,dead,dissolving,preSpawning,spawning,reviving,fastReviving,stunned,cower: return false;
	}
}

void updateCreatureAI(B)(ref MovingObject!B object,ObjectState!B state){
	if(!requiresAI(object.creatureState.mode)) return;
	switch(object.creatureAI.order.command){
		case CommandType.retreat:
			auto targetId=object.creatureAI.order.target.id;
			if(!state.isValidId(targetId)||!isValidGuardTarget(targetId,state))
				targetId=object.creatureAI.order.target.id=0;
			Vector3f targetPosition;
			if(targetId) targetPosition=state.movingObjectById!((obj)=>obj.position,()=>Vector3f.init)(targetId);
			if(targetPosition !is Vector3f.init) object.retreatTowards(targetPosition,state);
			else object.clearOrder(state);
			break;
		case CommandType.move:
			auto targetPosition=object.creatureAI.order.getTargetPosition(state);
			if(!object.moveTo(targetPosition,object.creatureAI.order.targetFacing,state))
				object.clearOrder(state);
			break;
		case CommandType.guard:
			auto targetId=object.creatureAI.order.target.id;
			if(!state.isValidId(targetId)||!object.guard(targetId,state)) targetId=object.creatureAI.order.target.id=0;
			if(targetId==0&&!object.patrol(state)) goto case CommandType.move;
			break;
		case CommandType.guardArea:
			auto targetPosition=object.creatureAI.order.getTargetPosition(state);
			if(!object.patrolAround(targetPosition,guardDistance,state))
				object.moveTo(targetPosition,object.creatureAI.order.targetFacing,state);
			break;
		case CommandType.attack:
			auto targetId=object.creatureAI.order.target.id;
			if(!state.isValidId(targetId)||!object.attack(targetId,state)) targetId=object.creatureAI.order.target.id=0;
			if(targetId==0&&!object.patrol(state)) goto case CommandType.move;
			break;
		case CommandType.advance:
			auto targetPosition=object.creatureAI.order.getTargetPosition(state);
			if(!object.advance(targetPosition,state))
				object.moveTo(targetPosition,object.creatureAI.order.targetFacing,state);
			break;
		case CommandType.none:
			if(object.isPeasant){
				if(object.creatureState.mode!=CreatureMode.cower){
					auto shelter=state.proximity.closestPeasantShelterInRange(object.side,object.position,shelterDistance,state);
					if(shelter){
						if(auto enemy=state.proximity.closestEnemyInRange(object.side,object.position,scareDistance,EnemyType.creature,state)){
							auto enemyPosition=state.movingObjectById!((obj)=>obj.position,function Vector3f(){ assert(0); })(enemy);
							// TODO: figure out the original rule for this
							if(object.creatureState.mode==CreatureMode.idle&&object.creatureState.timer>=updateFPS)
								playSoundTypeAt(object.sacObject,object.id,SoundType.run,state);
							object.moveTowards(object.position-(enemyPosition-object.position),state);
						}else object.stopMovement(state);
					}else object.startCowering(state);
				}
			}else if(object.isAggressive(state)){
				if(!object.patrol(state)){
					object.stopMovement(state);
					object.stopTurning(state);
					if(object.creatureState.movement==CreatureMovement.flying){
						object.creatureState.speedLimit=0.0f;
						object.pitch(0.0f,state);
					}
				}
			}
			break;
		default: assert(0); // TODO: compilation error would be better
	}
}

void updateCreatureState(B)(ref MovingObject!B object, ObjectState!B state){
	auto sacObject=object.sacObject;
	final switch(object.creatureState.mode){
		case CreatureMode.idle, CreatureMode.moving:
			auto oldMode=object.creatureState.mode;
			auto newMode=object.creatureState.movementDirection==MovementDirection.none?CreatureMode.idle:CreatureMode.moving;
			object.creatureState.timer+=1;
			object.frame+=1;
			if(object.frame>=sacObject.numFrames(object.animationState)*updateAnimFactor){
				object.frame=0;
				object.creatureState.mode=newMode;
				object.setCreatureState(state);
			}else if(newMode!=oldMode && object.creatureState.timer>=0.1f*updateFPS){
				object.creatureState.mode=newMode;
				object.setCreatureState(state);
			}
			if(oldMode==newMode&&newMode==CreatureMode.idle && object.animationState.among(AnimationState.run,AnimationState.walk) && object.creatureState.timer>=0.1f*updateFPS){
				object.animationState=AnimationState.stance1;
				object.setCreatureState(state);
			}
			break;
		case CreatureMode.dying:
			with(AnimationState) assert(object.animationState.among(death0,death1,death2,flyDeath,falling,tumble,hitFloor),text(sacObject.tag," ",object.animationState));
			if(object.creatureState.movement==CreatureMovement.tumbling){
				if(state.isOnGround(object.position)){
					if(object.creatureState.fallingVelocity.z<=0.0f&&object.position.z<=state.getGroundHeight(object.position)){
						object.creatureState.movement=CreatureMovement.onGround;
						with(AnimationState)
						if(sacObject.canFly && !object.animationState.among(hitFloor,death0,death1,death2)){
							object.frame=0;
							object.animationState=AnimationState.hitFloor;
						}else object.setCreatureState(state);
						break;
					}
				}
			}
			object.frame+=1;
			if(object.frame>=sacObject.numFrames(object.animationState)*updateAnimFactor){
				object.frame=0;
				final switch(object.creatureState.movement){
					case CreatureMovement.onGround:
						object.frame=sacObject.numFrames(object.animationState)*updateAnimFactor-1;
						object.creatureState.mode=CreatureMode.dead;
						object.spawnSoul(state);
						object.unselect(state);
						object.removeFromGroups(state);
						break;
					case CreatureMovement.flying:
						object.creatureState.movement=CreatureMovement.tumbling;
						object.creatureState.fallingVelocity=Vector3f(0.0f,0.0f,0.0f);
						object.setCreatureState(state);
						break;
					case CreatureMovement.tumbling:
						with(AnimationState)
						if(!sacObject.mustFly&&object.animationState.among(death0,death1,death2))
							goto case CreatureMovement.onGround;
						// continue tumbling
						break;
				}
			}
			break;
		case CreatureMode.preSpawning:
			break;
		case CreatureMode.spawning:
			assert(object.animationState==AnimationState.disoriented);
			// TODO: keep it stuck at frame 0 and make it transparent until casting finished.
			object.frame+=1;
			object.creatureState.movement=sacObject.mustFly?CreatureMovement.flying:CreatureMovement.onGround;
			if(!state.isOnGround(object.position)||state.getGroundHeight(object.position)<object.position.z){
				if(object.creatureState.movement!=CreatureMovement.flying){
					object.creatureState.movement=CreatureMovement.tumbling;
					object.frame=0;
					object.startIdling(state);
					break;
				}
			}else object.position.z=state.getGroundHeight(object.position);
			object.creatureState.mode=CreatureMode.idle;
			if(object.frame>=sacObject.numFrames(object.animationState)*updateAnimFactor){ // (just for robustness)
				object.frame=0;
				object.startIdling(state);
			}
			break;
		case CreatureMode.dead:
			with(AnimationState) assert(object.animationState.among(hitFloor,death0,death1,death2));
			assert(object.frame==sacObject.numFrames(object.animationState)*updateAnimFactor-1);
			if(object.creatureState.movement==CreatureMovement.tumbling&&object.creatureState.fallingVelocity.z<=0.0f){
				if(state.isOnGround(object.position)&&object.position.z<=state.getGroundHeight(object.position))
					object.creatureState.movement=CreatureMovement.onGround;
			}
			break;
		case CreatureMode.dissolving:
			object.creatureState.timer+=1;
			if(object.creatureState.timer==dissolutionDelay){
				playSoundAt("1ngi",object.id,state);
				// TODO: add particle effect
			}
			if(object.creatureState.timer>=dissolutionTime)
				state.removeLater(object.id);
			break;

		case CreatureMode.reviving, CreatureMode.fastReviving:
			static immutable reviveSequence=[AnimationState.corpse,AnimationState.float_];
			auto reviveTime=cast(int)(object.creatureStats.reviveTime*updateFPS);
			if(object.creatureState.mode==CreatureMode.fastReviving) reviveTime/=2;
			auto totalNumFrames=0;
			foreach(i,animationState;reviveSequence)
				if(sacObject.hasAnimationState(animationState))
					while(totalNumFrames<reviveTime){
						totalNumFrames+=sacObject.numFrames(animationState)*updateAnimFactor;
						if(i+1!=reviveSequence.length) break;
					}

			if(totalNumFrames==0) totalNumFrames=reviveTime;
			assert(totalNumFrames!=0);
			object.creatureState.timer+=1;
			object.creatureState.facing+=(object.creatureState.mode==CreatureMode.fastReviving?2.0f*cast(float)PI:4.0f*PI)/totalNumFrames;
			while(object.creatureState.facing>cast(float)PI) object.creatureState.facing-=2*cast(float)PI;
			if(object.creatureState.timer<totalNumFrames/2){
				object.creatureState.movement=CreatureMovement.flying;
				object.position.z+=object.creatureStats.reviveHeight/(totalNumFrames/2);
			}
			object.rotation=facingQuaternion(object.creatureState.facing);
			void finish(){
				if(object.soulId){
					state.removeLater(object.soulId);
					object.soulId=0;
				}
				if(sacObject.canFly) object.creatureState.targetFlyingHeight=0.0f;
				object.creatureState.movement=CreatureMovement.tumbling;
				object.creatureState.fallingVelocity=Vector3f(0.0f,0.0f,0.0f);
				object.startIdling(state);
			}
			if(reviveSequence.canFind(object.animationState)){
				object.frame+=1;
				if(object.frame>=sacObject.numFrames(object.animationState)*updateAnimFactor){
					object.frame=0;
					if(object.creatureState.timer<totalNumFrames) object.pickNextAnimation(reviveSequence,state);
					else finish();
				}
			}else if(object.creatureState.timer>=totalNumFrames){
				object.frame=0;
				finish();
			}
			break;
		case CreatureMode.takeoff:
			assert(sacObject.canFly);
			assert(object.creatureState.movement==CreatureMovement.onGround);
			object.frame+=1;
			if(object.frame>=sacObject.numFrames(object.animationState)*updateAnimFactor){
				object.frame=0;
				if(object.animationState==AnimationState.takeoff){
					object.creatureState.mode=sacObject.movingAfterTakeoff?CreatureMode.moving:CreatureMode.idle;
					object.creatureState.movement=CreatureMovement.flying;
					object.creatureState.speedLimit=0.0f;
				}
				object.setCreatureState(state);
			}
			break;
		case CreatureMode.landing:
			assert(sacObject.canFly&&!sacObject.mustFly);
			object.frame+=1;
			if(object.frame>=sacObject.numFrames(object.animationState)*updateAnimFactor){
				object.frame=0;
				object.setCreatureState(state);
			}
			break;
		case CreatureMode.meleeMoving,CreatureMode.meleeAttacking:
			object.frame+=1;
			if(object.frame>=sacObject.numFrames(object.animationState)*updateAnimFactor){
				object.frame=0;
				object.creatureState.mode=CreatureMode.idle;
				object.setCreatureState(state);
			}
			break;
		case CreatureMode.stunned:
			with(AnimationState) assert(object.animationState.among(stance1,knocked2Floor,falling,tumble,hitFloor,getUp,damageFront,damageRight,damageBack,damageLeft,damageTop,flyDamage));
			if(object.creatureState.movement==CreatureMovement.tumbling&&object.creatureState.fallingVelocity.z<=0.0f){
				if(sacObject.canFly){
					object.creatureState.movement=CreatureMovement.flying;
					object.creatureState.speedLimit=0.0f;
					object.frame=0;
					object.animationState=AnimationState.hover;
					object.startIdling(state);
					break;
				}else if(state.isOnGround(object.position)&&object.position.z<=state.getGroundHeight(object.position)){
					object.creatureState.movement=CreatureMovement.onGround;
					if(object.animationState.among(AnimationState.falling,AnimationState.tumble)){
						if(sacObject.hasHitFloor){
							object.frame=0;
							object.animationState=AnimationState.hitFloor;
						}else object.startIdling(state);
					}
					break;
				}
			}
			object.frame+=1;
			if(object.frame>=sacObject.numFrames(object.animationState)*updateAnimFactor){
				object.frame=0;
				final switch(object.creatureState.movement){
					case CreatureMovement.onGround:
						if(object.animationState.among(AnimationState.knocked2Floor,AnimationState.hitFloor)&&sacObject.hasGetUp){
							object.animationState=AnimationState.getUp;
						}else object.startIdling(state);
						break;
					case CreatureMovement.flying:
						object.startIdling(state);
						break;
					case CreatureMovement.tumbling:
						if(object.animationState.among(AnimationState.knocked2Floor,AnimationState.getUp))
							goto case CreatureMovement.onGround;
						// continue tumbling
						break;
				}
			}
			break;
		case CreatureMode.cower:
			object.frame+=1;
			if(object.frame>=sacObject.numFrames(object.animationState)*updateAnimFactor)
				object.setCreatureState(state);
			break;
		case CreatureMode.casting,CreatureMode.castingMoving:
			auto newMode=object.creatureState.movementDirection==MovementDirection.none?CreatureMode.casting:CreatureMode.castingMoving;
			object.creatureState.mode=newMode;
			if(newMode==CreatureMode.castingMoving){
				if(object.animationState.among(AnimationState.spellcastStart,AnimationState.runSpellcastStart))
					object.animationState=AnimationState.runSpellcastStart;
				else if(object.animationState.among(AnimationState.spellcastEnd,AnimationState.runSpellcastEnd))
					object.animationState=AnimationState.runSpellcastEnd;
				else object.animationState=AnimationState.runSpellcast;
			}else{
				if(object.animationState.among(AnimationState.spellcastStart,AnimationState.runSpellcastStart))
					object.animationState=AnimationState.spellcastStart;
				else if(object.animationState.among(AnimationState.spellcastEnd,AnimationState.runSpellcastEnd))
					object.animationState=AnimationState.spellcastEnd;
				else object.animationState=AnimationState.spellcast;
			}
			goto Lcasting;
		case CreatureMode.stationaryCasting:
			if(object.animationState==AnimationState.spellcastEnd&&sacObject.castingTime(AnimationState.spellcastEnd)*updateAnimFactor<=object.frame){
				object.creatureState.mode=CreatureMode.casting;
				goto case CreatureMode.casting;
			}
		Lcasting:
			object.frame+=1;
			object.creatureState.timer-=1;
			object.creatureState.timer2-=1;
			if(object.creatureState.timer2<=0){
				if(object.animationState.among(AnimationState.spellcastEnd,AnimationState.runSpellcastEnd))
					object.creatureState.timer2=playSoundTypeAt!true(sacObject,object.id,SoundType.incantation,state,sacObject.castingTime(AnimationState.spellcastEnd)*updateAnimFactor-object.frame+updateFPS/2)+updateFPS/10;
				else object.creatureState.timer2=playSoundTypeAt!true(sacObject,object.id,SoundType.incantation,state)+updateFPS/10;
			}
			if(object.frame>=sacObject.numFrames(object.animationState)*updateAnimFactor){
				object.frame=0;
				if(object.animationState.among(AnimationState.spellcastEnd,AnimationState.runSpellcastEnd)){
					object.creatureState.mode=object.creatureState.mode==CreatureMode.castingMoving?CreatureMode.moving:CreatureMode.idle;
					object.setCreatureState(state);
					return;
				}
				if(object.animationState==AnimationState.spellcastStart)
					object.animationState=AnimationState.spellcast;
				else if(object.animationState==AnimationState.runSpellcastStart)
					object.animationState=AnimationState.runSpellcast;
				auto endAnimation=object.creatureState.mode==CreatureMode.castingMoving?AnimationState.runSpellcastEnd:AnimationState.spellcastEnd;
				if(sacObject.numFrames(endAnimation)*updateAnimFactor>=object.creatureState.timer)
					object.animationState=endAnimation;
			}
	}
}

alias CollisionTargetSide(bool active:true)=int;
alias CollisionTargetSide(bool active:false)=Seq!();
auto collisionTargetImpl(bool attackFilter=false,bool returnHitbox=false,B)(int ownId,CollisionTargetSide!attackFilter side,Vector3f[2] hitbox,Vector3f[2] movedHitbox,ObjectState!B state){
	struct CollisionState{
		Vector3f[2] hitbox;
		int ownId;
		static if(attackFilter) int side;
		int target=0;
		static if(returnHitbox) Vector3f[2] targetHitbox;
		static if(attackFilter) bool ally=false;
		float distance=float.infinity;
	}
	static void handleCollision(ProximityEntry entry,CollisionState *collisionState,ObjectState!B state){
		if(entry.id==collisionState.ownId) return;
		static if(attackFilter){
			auto noHealthAlly=state.objectById!((obj,state,side)=>tuple(obj.health(state)==0.0f,state.sides.getStance(side,.side(obj,state))==Stance.ally))(entry.id,state,collisionState.side);
			auto noHealth=noHealthAlly[0], ally=noHealthAlly[1];
			if(noHealth) return;
		}
		auto distance=meleeDistance(entry.hitbox,boxCenter(collisionState.hitbox));
		static if(attackFilter) auto pick=!collisionState.target||tuple(ally,distance)<tuple(collisionState.ally,collisionState.distance);
		else auto pick=!collisionState.target||distance<collisionState.distance;
		if(pick){
			collisionState.target=entry.id;
			static if(returnHitbox) collisionState.targetHitbox=entry.hitbox;
			static if(attackFilter) collisionState.ally=ally;
			collisionState.distance=distance;
		}
	}
	auto collisionState=CollisionState(hitbox,ownId,side);
	state.proximity.collide!handleCollision(movedHitbox,&collisionState,state);
	static if(returnHitbox) return tuple(collisionState.target,collisionState.targetHitbox);
	else return collisionState.target;
}
auto collisionTarget(B)(int ownId,Vector3f[2] hitbox,Vector3f[2] movedHitbox,ObjectState!B state){
	return collisionTargetImpl!(false,false,B)(ownId,hitbox,movedHitbox,state);
}
auto collisionTargetWithHitbox(B)(int ownId,Vector3f[2] hitbox,Vector3f[2] movedHitbox,ObjectState!B state){
	return collisionTargetImpl!(false,true,B)(ownId,hitbox,movedHitbox,state);
}
int meleeAttackTarget(B)(int ownId,int side,Vector3f[2] hitbox,Vector3f[2] meleeHitbox,ObjectState!B state){
	return collisionTargetImpl!(true,false,B)(ownId,side,hitbox,meleeHitbox,state);
}

int meleeAttackTarget(B)(ref MovingObject!B object,ObjectState!B state){
	auto hitbox=object.hitbox,meleeHitbox=object.meleeHitbox;
	return meleeAttackTarget(object.id,object.side,hitbox,meleeHitbox,state);
}

void updateCreatureStats(B)(ref MovingObject!B object, ObjectState!B state){
	if(object.isRegenerating)
		object.heal(object.creatureStats.regeneration/updateFPS,state);
	if(object.creatureStats.mana<object.creatureStats.maxMana)
		object.giveMana(state.manaRegenAt(object.side,object.position)/updateFPS,state);
	if(object.creatureState.mode.among(CreatureMode.meleeMoving,CreatureMode.meleeAttacking) && object.hasAttackTick){
		object.creatureState.mode=CreatureMode.meleeAttacking;
		if(auto target=object.meleeAttackTarget(state)){
			static void dealDamage(T)(ref T target,MovingObject!B* attacker,ObjectState!B state){
				static if(is(T==MovingObject!B)){
					target.dealMeleeDamage(*attacker,state);
				}else static if(is(T==StaticObject!B)){
					assert(target.buildingId);
					state.buildingById!((ref Building!B building,MovingObject!B* attacker,ObjectState!B state){
						building.dealMeleeDamage(*attacker,state);
					})(target.buildingId,attacker,state);
				}
			}
			state.objectById!dealDamage(target,&object,state);
		}
	}
}

void updateCreaturePosition(B)(ref MovingObject!B object, ObjectState!B state){
	auto newPosition=object.position;
	if(object.creatureState.mode.among(CreatureMode.idle,CreatureMode.moving,CreatureMode.stunned,CreatureMode.landing,CreatureMode.dying,CreatureMode.meleeMoving,CreatureMode.casting,CreatureMode.castingMoving)){
		auto rotationSpeed=object.creatureStats.rotationSpeed(object.creatureState.movement==CreatureMovement.flying)/updateFPS;
		auto pitchingSpeed=object.creatureStats.pitchingSpeed/updateFPS;
		bool isRotating=false;
		if(object.creatureState.mode.among(CreatureMode.idle,CreatureMode.moving,CreatureMode.meleeMoving,CreatureMode.casting,CreatureMode.castingMoving)&&
		   object.creatureState.movement!=CreatureMovement.tumbling
		){
			final switch(object.creatureState.rotationDirection){
				case RotationDirection.none:
					break;
				case RotationDirection.left:
					isRotating=true;
					object.creatureState.facing+=min(rotationSpeed,object.creatureState.rotationSpeedLimit);
					while(object.creatureState.facing>cast(float)PI) object.creatureState.facing-=2*cast(float)PI;
					break;
				case RotationDirection.right:
					isRotating=true;
					object.creatureState.facing-=min(rotationSpeed,object.creatureState.rotationSpeedLimit);
					while(object.creatureState.facing<cast(float)PI) object.creatureState.facing+=2*cast(float)PI;
				break;
			}
			final switch(object.creatureState.pitchingDirection){
				case PitchingDirection.none:
					break;
				case PitchingDirection.up:
					isRotating=true;
					object.creatureState.flyingPitch+=min(pitchingSpeed,object.creatureState.pitchingSpeedLimit);
					object.creatureState.flyingPitch=min(object.creatureState.flyingPitch,object.creatureStats.pitchUpperLimit);
					break;
				case PitchingDirection.down:
					isRotating=true;
					object.creatureState.flyingPitch-=min(pitchingSpeed,object.creatureState.pitchingSpeedLimit);
					object.creatureState.flyingPitch=max(object.creatureState.flyingPitch,object.creatureStats.pitchLowerLimit);
				break;
			}
		}
		auto facing=facingQuaternion(object.creatureState.facing);
		auto newRotation=facing;
		if(object.creatureState.movement==CreatureMovement.onGround||
		   object.animationState.among(AnimationState.land,AnimationState.hitFloor)
		){
			final switch(object.sacObject.rotateOnGround){
				case RotateOnGround.no:
					break;
				case RotateOnGround.sideways:
					newRotation=newRotation*rotationQuaternion(Axis.y,-atan(state.getGroundHeightDerivative(object.position, rotate(facing, Vector3f(1.0f,0.0f,0.0f)))));
					break;
				case RotateOnGround.completely:
					newRotation=newRotation*rotationQuaternion(Axis.x,atan(state.getGroundHeightDerivative(object.position, rotate(facing, Vector3f(0.0f,1.0f,0.0f)))));
					newRotation=newRotation*rotationQuaternion(Axis.y,-atan(state.getGroundHeightDerivative(object.position, rotate(facing, Vector3f(1.0f,0.0f,0.0f)))));
					break;
			}
		}else newRotation=newRotation*pitchQuaternion(object.creatureState.flyingPitch);
		if(isRotating||object.creatureState.mode!=CreatureMode.idle||
		   object.creatureState.movement==CreatureMovement.flying||
		   object.creatureState.movement==CreatureMovement.tumbling){
			auto diff=newRotation*object.rotation.conj();
			if(!isRotating){
				if(object.creatureState.movement==CreatureMovement.flying){
					rotationSpeed/=5;
				}else rotationSpeed/=2;
			}else rotationSpeed*=1.1f; // TODO: make rotation along z direction independent of remaining rotations?
			object.rotation=(limitRotation(diff,rotationSpeed)*object.rotation).normalized;
		}
	}
	auto facing=facingQuaternion(object.creatureState.facing);
	final switch(object.creatureState.movement){
		case CreatureMovement.onGround:
			if(!object.creatureState.mode.isMoving) break;
			void applyMovementOnGround(Vector3f direction){
				auto speed=object.speedOnGround(state)/updateFPS;
				auto derivative=state.getGroundHeightDerivative(object.position,direction);
				Vector3f newDirection=direction;
				if(derivative>0.0f){
					newDirection=Vector3f(direction.x,direction.y,derivative).normalized;
				}else if(derivative<0.0f){
					newDirection=Vector3f(direction.x,direction.y,derivative);
					auto maxFactor=object.creatureStats.maxDownwardSpeedFactor;
					if(newDirection.lengthsqr>maxFactor*maxFactor) newDirection=maxFactor*newDirection.normalized;
				}
				auto velocity=limitLengthInPlane(newDirection*speed,object.creatureState.speedLimit);
				newPosition=state.moveOnGround(object.position,velocity);
			}
			final switch(object.creatureState.movementDirection){
				case MovementDirection.none:
					break;
				case MovementDirection.forward:
					applyMovementOnGround(rotate(facingQuaternion(object.creatureState.facing), Vector3f(0.0f,1.0f,0.0f)));
					break;
				case MovementDirection.backward:
					applyMovementOnGround(rotate(facingQuaternion(object.creatureState.facing), Vector3f(0.0f,-1.0f,0.0f)));
					break;
			}
			break;
		case CreatureMovement.flying:
			auto targetFlyingHeight=object.creatureState.targetFlyingHeight;
			if(object.creatureState.mode.among(CreatureMode.landing,CreatureMode.idle)
			   ||object.creatureState.mode==CreatureMode.meleeAttacking&&object.position.z-state.getHeight(object.position)>targetFlyingHeight
			){
				if(object.creatureState.mode.among(CreatureMode.landing,CreatureMode.idle)) object.creatureState.targetFlyingHeight=float.nan;
				auto height=state.getHeight(newPosition);
				if(newPosition.z>height){
					auto downwardSpeed=object.creatureState.mode==CreatureMode.landing?object.creatureStats.landingSpeed/updateFPS:object.creatureStats.downwardHoverSpeed/updateFPS;
					newPosition.z-=downwardSpeed;
					if(state.isOnGround(newPosition)){
						if(newPosition.z<=height)
							newPosition.z=height;
					}
				}
				break;
			}
			if(!object.creatureState.mode.isMoving) break;
			void applyMovementInAir(Vector3f direction){
				auto speed=object.speedInAir(state)/updateFPS;
				newPosition=object.position+speed*direction;
				auto newHeight=state.getHeight(newPosition), upwardSpeed=0.0f;
				auto flyingHeight=newPosition.z-newHeight;
				if(targetFlyingHeight!is float.nan){
					if(flyingHeight<targetFlyingHeight){
						auto speedLimit=object.creatureStats.takeoffSpeed/updateFPS;
						upwardSpeed=min(targetFlyingHeight-flyingHeight,speedLimit);
					}else{
						auto speedLimit=object.creatureStats.downwardHoverSpeed/updateFPS;
						upwardSpeed=-min(flyingHeight-targetFlyingHeight,speedLimit);
					}
				}
				auto onGround=state.isOnGround(newPosition);
				if(onGround&&flyingHeight<0.0f) upwardSpeed=max(upwardSpeed,-flyingHeight);
				auto upwardFactor=object.creatureStats.upwardFlyingSpeedFactor;
				auto downwardFactor=object.creatureStats.downwardFlyingSpeedFactor;
				auto newDirection=Vector3f(direction.x,direction.y,direction.z+upwardSpeed).normalized;
				speed*=sqrt(newDirection.x^^2+newDirection.y^^2+(newDirection.z*(newDirection.z>0?upwardFactor:downwardFactor))^^2);
				auto velocity=limitLengthInPlane(speed*newDirection,object.creatureState.speedLimit);
				newPosition=object.position+velocity;
				if(onGround){
					// TODO: improve? original engine does this, but it can cause ultrafast ascending for flying creatures
					newPosition.z=max(newPosition.z,newHeight);
				}
			}
			final switch(object.creatureState.movementDirection){
				case MovementDirection.none:
					break;
				case MovementDirection.forward:
					applyMovementInAir(rotate(object.rotation,Vector3f(0.0f,1.0f,0.0f)));
					break;
				case MovementDirection.backward:
					assert(object.sacObject.canFlyBackward);
					applyMovementInAir(rotate(object.rotation,Vector3f(0.0f,-1.0f,0.0f)));
					break;
			}
			break;
		case CreatureMovement.tumbling:
			object.creatureState.fallingVelocity.z-=object.creatureStats.fallingAcceleration/updateFPS;
			newPosition=object.position+object.creatureState.fallingVelocity/updateFPS;
			if(object.creatureState.fallingVelocity.z<=0.0f && state.isOnGround(newPosition))
				newPosition.z=max(newPosition.z,state.getGroundHeight(newPosition));
			break;
	}
	auto proximity=state.proximity;
	auto relativeHitbox=object.relativeHitbox;
	Vector3f[2] hitbox=[relativeHitbox[0]+newPosition,relativeHitbox[1]+newPosition];
	bool posChanged=false, needsFixup=false, isColliding=false;
	auto fixupDirection=Vector3f(0.0f,0.0f,0.0f);
	void handleCollision(bool fixup)(ProximityEntry entry){
		if(entry.id==object.id) return;
		isColliding=true;
		enum CollisionDirection{ // which face of obstacle's hitbox was hit
			left,
			right,
			back,
			front,
			bottom,
			top,
		}
		auto collisionDirection=CollisionDirection.left;
		auto minOverlap=hitbox[1].x-entry.hitbox[0].x;
		auto cand=entry.hitbox[1].x-hitbox[0].x;
		if(cand<minOverlap){
			minOverlap=cand;
			collisionDirection=CollisionDirection.right;
		}
		cand=hitbox[1].y-entry.hitbox[0].y;
		if(cand<minOverlap){
			minOverlap=cand;
			collisionDirection=CollisionDirection.back;
		}
		cand=entry.hitbox[1].y-hitbox[0].y;
		if(cand<minOverlap){
			minOverlap=cand;
			collisionDirection=CollisionDirection.front;
		}
		final switch(object.creatureState.movement){
			case CreatureMovement.onGround:
				break;
			case CreatureMovement.flying:
				if(object.creatureState.mode==CreatureMode.landing) break;
				cand=hitbox[1].z-entry.hitbox[0].z;
				if(cand<minOverlap){
					minOverlap=cand;
					collisionDirection=CollisionDirection.bottom;
				}
				cand=entry.hitbox[1].z-hitbox[0].z;
				if(cand<minOverlap){
					minOverlap=cand;
					collisionDirection=CollisionDirection.top;
				}
				break;
			case CreatureMovement.tumbling:
				static if(!fixup){
					cand=entry.hitbox[1].z-hitbox[0].z;
					if(cand<minOverlap)
						object.creatureState.fallingVelocity.z=0.0f;
				}
				break;
		}
		final switch(collisionDirection){
			case CollisionDirection.left:
				static if(fixup) fixupDirection.x-=minOverlap;
				else newPosition.x=min(newPosition.x,object.position.x);
				break;
			case CollisionDirection.right:
				static if(fixup) fixupDirection.x+=minOverlap;
				else newPosition.x=max(newPosition.x,object.position.x);
				break;
			case CollisionDirection.back:
				static if(fixup) fixupDirection.y-=minOverlap;
				else newPosition.y=min(newPosition.y,object.position.y);
				break;
			case CollisionDirection.front:
				static if(fixup) fixupDirection.y+=minOverlap;
				else newPosition.y=max(newPosition.y,object.position.y);
				break;
			case CollisionDirection.bottom:
				static if(fixup) fixupDirection.z-=minOverlap;
				else newPosition.z=min(newPosition.z,object.position.z);
				break;
			case CollisionDirection.top:
				static if(fixup) fixupDirection.z+=minOverlap;
				else newPosition.z=max(newPosition.z,object.position.z);
				break;
		}
		static if(!fixup) posChanged=true;
		else needsFixup=true;
	}
	if(!object.creatureState.mode.among(CreatureMode.dead,CreatureMode.dissolving)){ // dead creatures do not participate in collision handling
		proximity.collide!(handleCollision!false)(hitbox);
		object.creatureAI.isColliding=isColliding;
		hitbox=[relativeHitbox[0]+newPosition,relativeHitbox[1]+newPosition];
		proximity.collide!(handleCollision!true)(hitbox);
		if(needsFixup){
			auto fixupSpeed=object.creatureStats.collisionFixupSpeed/updateFPS;
			if(fixupDirection.length>fixupSpeed)
				fixupDirection=fixupDirection.normalized*object.creatureStats.collisionFixupSpeed/updateFPS;
			final switch(object.creatureState.movement){
				case CreatureMovement.onGround:
					if(state.isOnGround(newPosition)) newPosition=state.moveOnGround(newPosition,fixupDirection);
					break;
				case CreatureMovement.flying, CreatureMovement.tumbling:
					newPosition+=fixupDirection;
					break;
			}
			posChanged=true;
		}
	}
	bool onGround=state.isOnGround(newPosition);
	if(object.creatureState.movement!=CreatureMovement.onGround||onGround){
		if(posChanged){
			// TODO: improve? original engine does this, but it can cause ultrafast ascending for flying creatures
			final switch(object.creatureState.movement){
				case CreatureMovement.onGround:
					newPosition.z=state.getGroundHeight(newPosition);
					break;
				case CreatureMovement.flying, CreatureMovement.tumbling:
					if(onGround) newPosition.z=max(newPosition.z,state.getGroundHeight(newPosition));
					break;
			}
		}
		object.position=newPosition;
	}
}

void updateCreature(B)(ref MovingObject!B object, ObjectState!B state){
	object.updateCreatureAI(state);
	object.updateCreatureState(state);
	object.updateCreaturePosition(state);
	object.updateCreatureStats(state);
}

void updateSoul(B)(ref Soul!B soul, ObjectState!B state){
	soul.frame+=1;
	soul.facing+=2*cast(float)PI/8.0f/updateFPS;
	while(soul.facing>cast(float)PI) soul.facing-=2*cast(float)PI;
	if(soul.frame==SacSoul!B.numFrames*updateAnimFactor)
		soul.frame=0;
	if(soul.creatureId&&soul.state!=SoulState.collecting)
		soul.position=state.movingObjectById!(soulPosition,()=>Vector3f(float.nan,float.nan,float.nan))(soul.creatureId);
	final switch(soul.state){
		case SoulState.normal:
			static struct State{
				int collector=0;
				int side=-1;
				float distancesqr=float.infinity;
				bool tied=false;
			}
			enum collectDistance=4.0f; // TODO: measure this
			static void process(B)(ref WizardInfo!B wizard,Soul!B* soul,State* pstate,ObjectState!B state){ // TODO: use proximity data structure?
				auto sidePosition=state.movingObjectById!((obj)=>tuple(obj.side,obj.center),function Tuple!(int,Vector3f)(){ assert(0); })(wizard.id);
				auto side=sidePosition[0],position=sidePosition[1];
				if((soul.position.xy-position.xy).lengthsqr>collectDistance^^2) return;
				if(abs(soul.position.z-position.z)>collectDistance) return;
				auto distancesqr=(soul.position-position).lengthsqr;
				if(soul.creatureId&&side!=soul.preferredSide) return;
				if(soul.preferredSide!=-1&&pstate.side==soul.preferredSide&&side!=soul.preferredSide) return;
				if(distancesqr>pstate.distancesqr) return;
				if(distancesqr==pstate.distancesqr){ pstate.tied=true; return; }
				*pstate=State(wizard.id,side,distancesqr,false);
			}
			State pstate;
			state.eachWizard!process(&soul,&pstate,state);
			if(pstate.collector&&!pstate.tied){
				soul.collectorId=pstate.collector;
				soul.state=SoulState.collecting;
				playSoundAt("rips",soul.collectorId,state,2.0f);
				auto wizard=state.getWizard(soul.collectorId);
				if(wizard) wizard.souls+=soul.number;
				if(soul.creatureId){
					state.movingObjectById!((ref creature,state){
						creature.soulId=0;
						creature.startDissolving(state);
					})(soul.creatureId,state);
				}
			}
			break;
		case SoulState.emerging:
			soul.scaling+=(1.0f/3.0f)/updateFPS;
			if(soul.scaling>=1.0f){
				soul.scaling=1.0f;
				soul.state=SoulState.normal;
			}
			break;
		case SoulState.reviving:
			assert(soul.creatureId!=0);
			soul.scaling-=2.0f/updateFPS;
			if(soul.scaling<=0.0f)
				soul.scaling=0.0f;
			break;
		case SoulState.collecting:
			assert(soul.collectorId!=0);
			auto previousScaling=soul.scaling;
			soul.scaling-=4.0f/updateFPS;
			// TODO: how to do this more nicely?
			auto factor=soul.scaling/previousScaling;
			soul.position=factor*soul.position+(1.0f-factor)*state.movingObjectById!((wiz)=>wiz.center+Vector3f(0.0f,0.0f,0.5f),()=>soul.position)(soul.collectorId);
			if(soul.scaling<=0.0f){
				soul.scaling=0.0f;
				state.removeLater(soul.id);
				soul.number=0;
			}
			break;
	}
}

void updateParticles(B)(ref Particles!B particles, ObjectState!B state){
	if(!particles.sacParticle) return;
	auto sacParticle=particles.sacParticle;
	auto gravity=sacParticle.gravity;
	for(int j=0;j<particles.length;){
		if(particles.lifetimes[j]<=0){
			particles.removeParticle(j);
			continue;
		}
		scope(success) j++;
		particles.lifetimes[j]-=1;
		particles.frames[j]+=1;
		if(particles.frames[j]>=sacParticle.numFrames){
			particles.frames[j]=0;
		}
		particles.positions[j]+=particles.velocities[j]/updateFPS;
		if(gravity) particles.velocities[j].z-=15.0f/updateFPS;
	}
}

bool updateDebris(B)(ref Debris!B debris,ObjectState!B state){
	auto oldPosition=debris.position;
	debris.position+=debris.velocity/updateFPS;
	debris.velocity.z-=30.0f/updateFPS;
	debris.rotation=debris.rotationUpdate*debris.rotation;
	if(state.isOnGround(debris.position)){
		auto height=state.getGroundHeight(debris.position);
		if(height>debris.position.z){
			if(height>debris.position.z+5.0f)
				return false;
			debris.position.z=height;
			debris.velocity.z*=-0.2f;
			if(debris.velocity.z<1.0f)
				return false;
		}
	}else if(debris.position.z<state.getHeight(debris.position)-1000.0f)
		return false;
	enum numParticles=3;
	auto sacParticle=SacParticle!B.get(ParticleType.firy);
	auto velocity=Vector3f(0.0f,0.0f,0.0f);
	auto lifetime=sacParticle.numFrames;
	auto frame=0;
	foreach(i;0..numParticles){
		auto position=oldPosition*((cast(float)numParticles-1-i)/(numParticles-1))+debris.position*(cast(float)i/(numParticles-1));
		position+=0.1f*Vector3f(state.uniform(-1.0f,1.0f),state.uniform(-1.0f,1.0f),state.uniform(-1.0f,1.0f));
		state.addParticle(Particle!B(sacParticle,position,velocity,lifetime,frame));
	}
	return true;
}
bool updateExplosion(B)(ref Explosion!B explosion,ObjectState!B state){
	with(explosion){
		frame+=1;
		if(frame>=32) frame=0;
		scale+=expansionSpeed/updateFPS;
		return scale<maxScale;
	}
}
enum CastingStatus{
	underway,
	interrupted,
	finished,
}
void drainMana(B)(ref MovingObject!B wizard,float manaCostPerFrame,ObjectState!B state){
	if(wizard.creatureState.timer>=0) // TODO: is this special for slime?eeeedddd
		wizard.creatureStats.mana=max(0.0f,wizard.creatureStats.mana-manaCostPerFrame);
}
CastingStatus castStatus(B)(ref MovingObject!B wizard,ObjectState!B state){
	with(wizard){
		if(!creatureState.mode.isCasting) return CastingStatus.interrupted;
		if(animationState.among(AnimationState.spellcastEnd,AnimationState.runSpellcastEnd)&&frame+1>=sacObject.castingTime(wizard.animationState)*updateAnimFactor)
			return CastingStatus.finished;
		return CastingStatus.underway;
	}
}
CastingStatus update(B)(ref ManaDrain!B manaDrain,ObjectState!B state){
	return state.movingObjectById!((ref obj,manaDrain,state){
		obj.drainMana(manaDrain.manaCostPerFrame,state);
		return obj.castStatus(state);
	},function CastingStatus(){ return CastingStatus.interrupted; })(manaDrain.wizard,manaDrain,state);
}
bool updateManaDrain(B)(ref ManaDrain!B manaDrain,ObjectState!B state){
	final switch(manaDrain.update(state)){
		case CastingStatus.underway: return true;
		case CastingStatus.interrupted, CastingStatus.finished: return false;
	}
}
bool updateCreatureCasting(B)(ref CreatureCasting!B creatureCast,ObjectState!B state){
	with(creatureCast){
		final switch(manaDrain.update(state)){
			case CastingStatus.underway:
				return true;
			case CastingStatus.interrupted: state.removeObject(creatureCast.creature); return false;
			case CastingStatus.finished:
				stopSoundsAt(creature,state);
				state.setRenderMode!(MovingObject!B,RenderMode.opaque)(creature);
				auto wizard=state.getWizard(manaDrain.wizard);
				if(!wizard||wizard.souls<spell.soulCost) goto case CastingStatus.interrupted;
				wizard.souls-=spell.soulCost;
				state.movingObjectById!((ref obj,state){
				obj.creatureState.mode=CreatureMode.spawning;
				state.addToSelection(obj.side,obj.id);
			},function(){})(creature,state); return false;
		}
	}
}
enum structureCastingGradientSize=2.0f;
bool updateStructureCasting(B)(ref StructureCasting!B structureCast,ObjectState!B state){
	with(structureCast){
		final switch(manaDrain.update(state)){
			case CastingStatus.underway:
				currentFrame+=1;
				auto thresholdZ=-structureCastingGradientSize+(buildingHeight+structureCastingGradientSize)*currentFrame/castingTime;
				state.buildingById!((bldg,thresholdZ,state){
					foreach(cid;bldg.componentIds){
						state.setThresholdZ(cid,thresholdZ);
						if(currentFrame+0.5f*updateFPS<castingTime){
							auto pos=state.staticObjectById!((obj)=>obj.position,function Vector3f(){ assert(0); })(cid);
							pos.z+=thresholdZ-0.5f*structureCastingGradientSize*currentFrame/castingTime;
							foreach(i;0..state.uniform(1,6)){
								auto position=pos;
								position.z+=state.uniform(0.0f,structureCastingGradientSize);
								auto scale=state.uniform(0.875f,1.125f);
								state.addEffect(BlueRing!B(position,scale,state.uniform(64)));
							}
						}
					}
				})(building,thresholdZ,state);
				return true;
			case CastingStatus.interrupted:
				state.buildingById!destroy(building,state);
				return false;
			case CastingStatus.finished:
				state.setRenderMode!(Building!B,RenderMode.opaque)(building);
				auto wizard=state.getWizard(manaDrain.wizard);
				if(!wizard||wizard.souls<spell.soulCost) goto case CastingStatus.interrupted;
				wizard.souls-=spell.soulCost;
				state.buildingById!((ref building,state){
					building.activate(state);
					building.flags&=~Flags.cannotDamage;
			},function(){})(building,state); return false;
		}
	}
}
bool updateBlueRing(B)(ref BlueRing!B blueRing,ObjectState!B state){
	with(blueRing){
		frame+=1;
		scale-=1.0f/updateFPS;
		if(scale<=0) return false;
		return true;
	}
}
bool updateSpeedUp(B)(ref SpeedUp!B speedUp,ObjectState!B state){
	with(speedUp){
		if(!state.isValidId(creature,TargetType.creature)) return false;
		framesLeft-=1;
		return state.movingObjectById!((ref obj,framesLeft,state){
			if(obj.health==0.0f) return false;
			if(!framesLeft){
				obj.creatureStats.effects.speedUp-=1;
				return false;
			}
			static assert(updateFPS==60);
			if(state.frame%2==0){
				auto hitbox=obj.hitbox;
				auto sacParticle=SacParticle!B.get(ParticleType.speedUp);
				state.addParticle(Particle!B(sacParticle,state.uniform(hitbox),Vector3f(0.0f,0.0f,0.0f),sacParticle.numFrames,0));
			}
			state.addEffect(SpeedUpShadow!B(obj.id,obj.position,obj.rotation,obj.animationState,obj.frame));
			return true;
		},()=>false)(creature,framesLeft,state);
	}
}

enum speedUpShadowLifetime=updateFPS/5;
enum speedUpShadowSpacing=speedUpShadowLifetime/3;
bool updateSpeedUpShadow(B)(ref SpeedUpShadow!B speedUpShadow,ObjectState!B state){
	with(speedUpShadow){
		if(++age>=speedUpShadowLifetime) return false;
		return true;
	}
}
void updateEffects(B)(ref Effects!B effects,ObjectState!B state){
	for(int i=0;i<effects.debris.length;){
		if(!updateDebris(effects.debris[i],state)){
			effects.removeDebris(i);
			continue;
		}
		i++;
	}
	for(int i=0;i<effects.explosions.length;){
		if(!updateExplosion(effects.explosions[i],state)){
			effects.removeExplosion(i);
			continue;
		}
		i++;
	}
	for(int i=0;i<effects.manaDrains.length;){
		if(!updateManaDrain(effects.manaDrains[i],state)){
			effects.removeManaDrain(i);
			continue;
		}
		i++;
	}
	for(int i=0;i<effects.creatureCasts.length;){
		if(!updateCreatureCasting(effects.creatureCasts[i],state)){
			effects.removeCreatureCasting(i);
			continue;
		}
		i++;
	}
	for(int i=0;i<effects.structureCasts.length;){
		if(!updateStructureCasting(effects.structureCasts[i],state)){
			effects.removeStructureCasting(i);
			continue;
		}
		i++;
	}
	for(int i=0;i<effects.blueRings.length;){
		if(!updateBlueRing(effects.blueRings[i],state)){
			effects.removeBlueRing(i);
			continue;
		}
		i++;
	}
	for(int i=0;i<effects.speedUps.length;){
		if(!updateSpeedUp(effects.speedUps[i],state)){
			effects.removeSpeedUp(i);
			continue;
		}
		i++;
	}
	for(int i=0;i<effects.speedUpShadows.length;){
		if(!updateSpeedUpShadow(effects.speedUpShadows[i],state)){
			effects.removeSpeedUpShadow(i);
			continue;
		}
		i++;
	}
}

void explosionAnimation(B)(Vector3f position,ObjectState!B state){
	playSoundAt("pxbf",position,state,10.0f);
	state.addEffect(Explosion!B(position,0.0f,30.0f,40.0f,0));
	state.addEffect(Explosion!B(position,0.0f,5.0f,10.0f,0));
	enum numParticles=200;
	auto sacParticle1=SacParticle!B.get(ParticleType.explosion);
	auto sacParticle2=SacParticle!B.get(ParticleType.explosion2);
	foreach(i;0..numParticles){
		auto direction=Vector3f(state.uniform(-1.0f,1.0f),state.uniform(-1.0f,1.0f),state.uniform(-1.0f,1.0f)).normalized;
		auto velocity=state.uniform(1.5f,6.0f)*direction;
		auto lifetime=31;
		auto frame=0;
		state.addParticle(Particle!B(i<numParticles/2?sacParticle1:sacParticle2,position,velocity,lifetime,frame));
	}
}

void destructionAnimation(B)(Vector3f position,ObjectState!B state){
	enum numDebris=35;
	foreach(i;0..numDebris){
		auto angle=state.uniform(-cast(float)PI,cast(float)PI);
		auto velocity=(20.0f+state.uniform(-5.0f,5.0f))*Vector3f(cos(angle),sin(angle),state.uniform(0.5f,2.0f)).normalized;
		auto rotationSpeed=cast(float)2*PI*state.uniform(0.5f,2.0f)/updateFPS;
		auto rotationAxis=Vector3f(state.uniform(-1.0f,1.0f),state.uniform(-1.0f,1.0f),state.uniform(-1.0f,1.0f)).normalized;
		auto rotationUpdate=rotationQuaternion(rotationAxis,rotationSpeed);
		auto debris=Debris!B(position,velocity,rotationUpdate,Quaternionf.identity());
		state.addEffect(debris);
	}
	explosionAnimation(position,state);
}

void updateCommandCones(B)(ref CommandCones!B commandCones, ObjectState!B state){
	with(commandCones) foreach(i;0..cast(int)cones.length){
		foreach(j;0..cast(int)cones[i].length){
			for(int k=0;k<cones[i][j].length;){
				if(cones[i][j][k].lifetime<=0){
					removeCommandCone(i,cast(CommandConeColor)j,k);
					continue;
				}
				scope(success) k++;
				cones[i][j][k].lifetime-=1;
			}
		}
	}
}

void animateManafount(B)(Vector3f location, ObjectState!B state){
	auto sacParticle=SacParticle!B.get(ParticleType.manafount);
	auto globalAngle=1.5f*2*cast(float)PI/updateFPS*(state.frame+1000*location.x+location.y);
	auto globalMagnitude=0.25f;
	auto globalDisplacement=globalMagnitude*Vector3f(cos(globalAngle),sin(globalAngle),0.0f);
	auto center=location+globalDisplacement;
	static assert(updateFPS==60); // TODO: fix
	foreach(j;0..2){
		auto displacementAngle=state.uniform(-cast(float)PI,cast(float)PI);
		auto displacementMagnitude=state.uniform(0.0f,0.5f);
		auto displacement=displacementMagnitude*Vector3f(cos(displacementAngle),sin(displacementAngle),0.0f);
		foreach(k;0..2){
			auto position=center+displacement;
			auto angle=state.uniform(-cast(float)PI,cast(float)PI);
			auto velocity=(20.0f+state.uniform(-5.0f,5.0f))*Vector3f(cos(angle),sin(angle),state.uniform(2.0f,4.0f)).normalized;
			auto lifetime=cast(int)(sqrt(sacParticle.numFrames*5.0f)*state.uniform(0.0f,1.0f))^^2;
			auto frame=0;
			state.addParticle(Particle!B(sacParticle,position,velocity,lifetime,frame));
		}
	}
}

void animateManalith(B)(Vector3f location, int side, ObjectState!B state){
	auto sacParticle=state.sides.manaParticle(side);
	auto globalAngle=2*cast(float)PI/updateFPS*(state.frame+1000*location.x+location.y);
	auto globalMagnitude=0.5f;
	auto globalDisplacement=globalMagnitude*Vector3f(cos(globalAngle),sin(globalAngle),0.0f);
	auto center=location+globalDisplacement;
	static assert(updateFPS==60); // TODO: fix
	foreach(j;0..4){
		auto displacementAngle=state.uniform(-cast(float)PI,cast(float)PI);
		auto displacementMagnitude=3.5f*state.uniform(0.0f,1.0f)^^2;
		auto displacement=displacementMagnitude*Vector3f(cos(displacementAngle),sin(displacementAngle),0.0f);
		auto position=center+displacement;
		auto angle=state.uniform(-cast(float)PI,cast(float)PI);
		auto velocity=(15.0f+state.uniform(-5.0f,5.0f))*Vector3f(0.0f,0.0f,state.uniform(2.0f,4.0f)).normalized;
		auto lifetime=cast(int)(sacParticle.numFrames*5.0f-0.7*sacParticle.numFrames*displacement.length*state.uniform(0.0f,1.0f)^^2);
		auto frame=0;
		state.addParticle(Particle!B(sacParticle,position,velocity,lifetime,frame));
	}
}

void animateShrine(B)(Vector3f location, int side, ObjectState!B state){
	auto sacParticle=state.sides.shrineParticle(side);
	auto globalAngle=2*cast(float)PI/updateFPS*(state.frame+1000*location.x+location.y);
	auto globalMagnitude=0.1f;
	auto globalDisplacement=globalMagnitude*Vector3f(cos(globalAngle),sin(globalAngle),0.0f);
	auto center=location+globalDisplacement;
	static assert(updateFPS==60); // TODO: fix
	foreach(j;0..2){
		auto displacementAngle=state.uniform(-cast(float)PI,cast(float)PI);
		auto displacementMagnitude=1.0f*state.uniform(0.0f,1.0f)^^2;
		auto displacement=displacementMagnitude*Vector3f(cos(displacementAngle),sin(displacementAngle),0.0f);
		auto position=center+displacement;
		auto angle=state.uniform(-cast(float)PI,cast(float)PI);
		auto velocity=(1.5f+state.uniform(-0.5f,0.5f))*Vector3f(0.0f,0.0f,state.uniform(2.0f,4.0f)).normalized;
		auto lifetime=cast(int)((sacParticle.numFrames*5.0f)*(1.0f+state.uniform(0.0f,1.0f)^^10));
		auto frame=0;
		state.addParticle(Particle!B(sacParticle,position,velocity,lifetime,frame));
	}
}

void updateBuilding(B)(ref Building!B building, ObjectState!B state){
	if(building.componentIds.length==0) return;
	if(building.health!=0.0f) building.heal(building.regeneration/updateFPS,state);
	if(building.isManafount){
		if(building.top==0 && !(building.flags&AdditionalBuildingFlags.inactive)){
			Vector3f getManafountTop(StaticObject!B obj){
				auto hitbox=obj.hitboxes[0];
				auto center=0.5f*(hitbox[0]+hitbox[1]);
				return center+Vector3f(0.0f,0.0f,0.75f);
			}
			auto position=state.staticObjectById!(getManafountTop,function Vector3f(){ assert(0); })(building.componentIds[0]);
			animateManafount(position,state);
		}
	}else if(building.isManalith){
		if(!(building.flags&AdditionalBuildingFlags.inactive)){
			Vector3f getCenter(StaticObject!B obj){
				return obj.position+Vector3f(0.0f,0.0f,15.0f);
			}
			auto position=state.staticObjectById!(getCenter,function Vector3f(){ assert(0); })(building.componentIds[0]);
			animateManalith(position,building.side,state);
		}
	}else if(building.isShrine||building.isAltar){
		if(!(building.flags&AdditionalBuildingFlags.inactive)){
			Vector3f getShrineTop(StaticObject!B obj){
				return obj.position+Vector3f(0.0f,0.0f,3.0f);
			}
			auto position=state.staticObjectById!(getShrineTop,function Vector3f(){ assert(0); })(building.componentIds[0]);
			if(building.isEtherealAltar) position.z+=95.0f;
			animateShrine(position,building.side,state);
		}
	}
}

void animateManahoar(B)(Vector3f location, int side, float rate, ObjectState!B state){
	auto sacParticle=state.sides.manahoarParticle(side);
	auto globalAngle=2*cast(float)PI/updateFPS*state.frame;
	auto globalMagnitude=0.05f;
	auto globalDisplacement=globalMagnitude*Vector3f(cos(globalAngle),sin(globalAngle),0.0f);
	auto center=location+globalDisplacement;
	auto noisyRate=rate*state.uniform(0.91f,1.09f);
	auto perFrame=noisyRate/updateFPS;
	auto fractional=cast(int)(1.0f/fmod(perFrame,1.0f));
	auto numParticles=cast(int)perFrame+(fractional!=0&&state.frame%fractional==0?1:0);
	foreach(j;0..numParticles){
		auto displacementAngle=state.uniform(-cast(float)PI,cast(float)PI);
		auto displacementMagnitude=0.15f*state.uniform(0.0f,1.0f)^^2;
		auto displacement=displacementMagnitude*Vector3f(cos(displacementAngle),sin(displacementAngle),0.0f);
		auto position=center+displacement;
		auto angle=state.uniform(-cast(float)PI,cast(float)PI);
		auto velocity=(1.5f+state.uniform(-0.5f,0.5f))*Vector3f(0.0f,0.0f,state.uniform(2.0f,4.0f)).normalized;
		auto lifetime=cast(int)(0.7f*(sacParticle.numFrames*5.0f-7.0f*sacParticle.numFrames*displacement.length*state.uniform(0.0f,1.0f)^^2));
		auto frame=0;
		state.addParticle(Particle!B(sacParticle,position,velocity,lifetime,frame));
	}
}

enum SpellbookSoundFlags{
	none,
	creatureTab=1,
	spellTab=2,
	structureTab=4,
}
void playSpellbookSound(B)(int side,SpellbookSoundFlags flags,char[4] tag,ObjectState!B state,float gain=1.0f){
	static if(B.hasAudio) if(playAudio) B.playSpellbookSound(side,flags,tag,gain);
}
void updateWizard(B)(ref WizardInfo!B wizard,ObjectState!B state){
	int side=state.movingObjectById!((obj)=>obj.side,()=>-1)(wizard.id);
	SpellbookSoundFlags flags;
	foreach(ref entry;wizard.spellbook.spells.data){
		bool oldReady=entry.ready;
		entry.cooldown=max(0.0f,entry.cooldown-1.0f/updateFPS);
		entry.ready=state.spellStatus!true(wizard.id,entry.spell)==SpellStatus.ready;
		if(entry.readyFrame<16*updateAnimFactor) entry.readyFrame+=1;
		if(!oldReady&&entry.ready){
			final switch(entry.spell.type){
				case SpellType.creature: flags|=SpellbookSoundFlags.creatureTab; break;
				case SpellType.spell: flags|=SpellbookSoundFlags.spellTab; break;
				case SpellType.structure: flags|=SpellbookSoundFlags.structureTab; break;
			}
			entry.readyFrame=0;
		}
	}
	playSpellbookSound(side,flags,"vaps",state);
}


void addToProximity(T,B)(ref T objects, ObjectState!B state){
	auto proximity=state.proximity;
	enum isMoving=is(T==MovingObjects!(B, renderMode), RenderMode renderMode);
	enum isStatic=is(T==StaticObjects!(B, renderMode), RenderMode renderMode);
	static if(isMoving){
		foreach(j;0..objects.length){
			if(objects.creatureStates[j].mode.among(CreatureMode.dead,CreatureMode.dissolving)) continue; // dead creatures are not obstacles (bad cache locality)
			auto hitbox=objects.sacObject.hitbox(objects.rotations[j],objects.animationStates[j],objects.frames[j]/updateAnimFactor);
			auto position=objects.positions[j];
			hitbox[0]+=position;
			hitbox[1]+=position;
			proximity.insert(ProximityEntry(objects.ids[j],hitbox));
			if(objects.creatureStatss[j].health!=0.0f){
				int attackTargetId=0;
				if(objects.creatureAIs[j].order.command==CommandType.attack)
					attackTargetId=objects.creatureAIs[j].order.target.id;
				proximity.insertCenter(CenterProximityEntry(false,objects.ids[j],objects.sides[j],boxCenter(hitbox),attackTargetId));
			}
		}
		if(objects.sacObject.isManahoar){
			static bool manahoarAbilityEnabled(CreatureMode mode){
				final switch(mode) with(CreatureMode){
					case idle,moving,dying,spawning,takeoff,landing,meleeMoving,meleeAttacking,stunned,cower: return true;
					case dead,dissolving,preSpawning,reviving,fastReviving: return false;
					case casting,stationaryCasting,castingMoving: assert(0);
				}
			}
			foreach(j;0..objects.length){
				auto mode=objects.creatureStates[j].mode;
				if(!manahoarAbilityEnabled(mode)) continue;
				auto flameLocation=objects.positions[j]+rotate(objects.rotations[j],objects.sacObject.manahoarManaOffset(objects.animationStates[j],objects.frames[j]/updateAnimFactor));
				auto rate=proximity.addManahoar(objects.sides[j],objects.ids[j],objects.positions[j],state);
				animateManahoar(flameLocation,objects.sides[j],rate,state);
			}
		}
	}else static if(isStatic){ // TODO: cache those?
		foreach(j;0..objects.length){
			foreach(hitbox;objects.sacObject.hitboxes(objects.rotations[j])){
				auto position=objects.positions[j];
				hitbox[0]+=position;
				hitbox[1]+=position;
				proximity.insert(ProximityEntry(objects.ids[j],hitbox));
				auto buildingId=objects.buildingIds[j];
				// this needs to be kept in synch with isValidAttackTarget
				auto healthFlags=state.buildingById!((ref b)=>tuple(b.health,b.flags),function Tuple!(float,int){ assert(0); })(buildingId);
				auto health=healthFlags[0],flags=healthFlags[1];
				if(!(flags&Flags.notOnMinimap))
					proximity.insertCenter(CenterProximityEntry(true,objects.ids[j],sideFromBuildingId(buildingId,state),boxCenter(hitbox),0,health==0.0f));
			}
		}
		// TODO: get rid of duplication here
		if(objects.sacObject.isManafount){
			foreach(j;0..objects.length)
				if(state.buildingById!(obj=>!obj.top,()=>false)(objects.buildingIds[j]))
					proximity.addManafount(objects.positions[j]);
		}else if(objects.sacObject.isManalith){
			foreach(j;0..objects.length)
				proximity.addManalith(sideFromBuildingId(objects.buildingIds[j],state),objects.positions[j]);
		}else if(objects.sacObject.isShrine){
			foreach(j;0..objects.length)
				proximity.addShrine(sideFromBuildingId(objects.buildingIds[j],state),objects.positions[j]);
		}else if(objects.sacObject.isAltar){
			foreach(j;0..objects.length)
				proximity.addAltar(sideFromBuildingId(objects.buildingIds[j],state),objects.positions[j]);
		}
	}else static if(is(T==Souls!B)||is(T==Buildings!B)||is(T==FixedObjects!B)||is(T==Effects!B)||is(T==Particles!B)||is(T==CommandCones!B)){
		// do nothing
	}else static assert(0);
}

struct ProximityEntry{
	int id;
	Vector3f[2] hitbox;
}
struct ProximityEntries{
	int version_=0;
	Array!ProximityEntry entries; // TODO: be more clever here if many entries
	void insert(int version_,ProximityEntry entry){
		if(this.version_!=version_){
			entries.length=0;
			this.version_=version_;
		}
		entries~=entry;
	}
}
auto collide(alias f,T...)(ref ProximityEntries proximityEntries,int version_,Vector3f[2] hitbox,T args){
	if(proximityEntries.version_!=version_){
		proximityEntries.entries.length=0;
		proximityEntries.version_=version_;
	}
	foreach(i;0..proximityEntries.entries.length){
		if(boxesIntersect(proximityEntries.entries[i].hitbox,hitbox))
			f(proximityEntries.entries[i],args);
	}
}

struct HitboxProximity(B){
	enum resolution=10;
	enum offMapSlack=100/resolution;
	enum size=(2560+resolution-1)/resolution+2*offMapSlack;
	static Tuple!(int,"j",int,"i") getTile(Vector3f position){
		return tuple!("j","i")(cast(int)(position.y/resolution),cast(int)(position.x/resolution)); // TODO: good resolution?
	}
	ProximityEntries[size][size] data;
	ProximityEntries offMap;
	void insert(int version_,ProximityEntry entry){
		auto lowTile=getTile(entry.hitbox[0]), highTile=getTile(entry.hitbox[1]);
		if(lowTile.j+offMapSlack<0||lowTile.i+offMapSlack<0||highTile.j+offMapSlack>=size||highTile.i+offMapSlack>=size)
			offMap.insert(version_,entry);
		foreach(j;max(0,lowTile.j+offMapSlack)..min(highTile.j+offMapSlack+1,size))
			foreach(i;max(0,lowTile.i+offMapSlack)..min(highTile.i+offMapSlack+1,size))
				data[j][i].insert(version_,entry);
	}
}
auto collide(alias f,B,T...)(ref HitboxProximity!B proximity,int version_,Vector3f[2] hitbox,T args){
	with(proximity){
		auto lowTile=getTile(hitbox[0]), highTile=getTile(hitbox[1]);
		if(lowTile.j+offMapSlack<0||lowTile.i+offMapSlack<0||highTile.j+offMapSlack>=size||highTile.i+offMapSlack>=size)
			offMap.collide!f(version_,hitbox,args);
		foreach(j;max(0,lowTile.j+offMapSlack)..min(highTile.j+offMapSlack+1,size))
			foreach(i;max(0,lowTile.i+offMapSlack)..min(highTile.i+offMapSlack+1,size))
				data[j][i].collide!f(version_,hitbox,args);
	}
}

struct ManaEntry{
	bool allies;
	int side;
	Vector3f position;
	float radius;
	float rate;
}
struct ManaEntries{
	int version_=0;
	Array!ManaEntry entries; // TODO: be more clever here if many entries
	void insert(int version_,ManaEntry entry){
		if(this.version_!=version_){
			entries.length=0;
			this.version_=version_;
		}
		entries~=entry;
	}
	float manaRegenAt(B)(int version_,int side,Vector3f position,ObjectState!B state){
		if(this.version_!=version_){
			entries.length=0;
			this.version_=version_;
		}
		auto sides=state.sides;
		float rate=0.0f;
		foreach(ref entry;entries){
			auto distance=(position.xy-entry.position.xy).length;
			if(distance>=entry.radius) continue;
			if(entry.side!=-1&&(!entry.allies?entry.side!=side:sides.getStance(entry.side,side)!=Stance.ally)) continue;
			rate+=entry.rate;
		}
		return rate;
	}
}


struct ManaProximity(B){
	enum resolution=50;
	enum offMapSlack=100/resolution;
	enum size=(2560+resolution-1)/resolution+2*offMapSlack;
	static Tuple!(int,"j",int,"i") getTile(Vector3f position){
		return tuple!("j","i")(cast(int)(position.y/resolution),cast(int)(position.x/resolution)); // TODO: good resolution?
	}
	ManaEntries[size][size] data;
	ManaEntries offMap;
	struct ManalithEntry{
		int side;
		Vector3f position;
	}
	int manalithVersion;
	Array!ManalithEntry manaliths;
	void addEntry(int version_,ManaEntry entry){
		auto tile=getTile(entry.position);
		if(tile.j+offMapSlack<0||tile.i+offMapSlack<0||tile.j+offMapSlack>=size||tile.i+offMapSlack>=size) offMap.insert(version_,entry);
		else data[tile.j+offMapSlack][tile.i+offMapSlack].insert(version_,entry);
	}
	void addManafount(int version_,Vector3f position){
		addEntry(version_,ManaEntry(true,-1,position,50.0f,1000.0f/30.0f));
	}
	void addManalith(int version_,int side,Vector3f position){
		if(manalithVersion!=version_){
			manaliths.length=0;
			manalithVersion=version_;
		}
		manaliths~=ManalithEntry(side,position);
		addEntry(version_,ManaEntry(true,side,position,50.0f,1000.0f/30.0f));
	}
	void addAltar(int version_,int side,Vector3f position){
		addEntry(version_,ManaEntry(true,side,position,50.0f,1000.0f/60.0f));
	}
	void addShrine(int version_,int side,Vector3f position){
		addEntry(version_,ManaEntry(true,side,position,50.0f,1000.0f/120.0f));
	}
	float addManahoar(int version_,int side,Vector3f position,ObjectState!B state){
		if(manalithVersion!=version_){
			manaliths.length=0;
			manalithVersion=version_;
		}
		float rate=0.0f;
		auto sides=state.sides;
		foreach(ref manalith;manaliths){
			if(sides.getStance(manalith.side,side)!=Stance.ally) continue;
			auto distance=(position.xy-manalith.position.xy).length;
			rate+=max(0.0f,min((20.0f/50.0f)*distance,(20.0f/(1000.0f-50.0f))*(1000.0f-distance)));
		}
		addEntry(version_,ManaEntry(false,side,position,40.0f,rate));
		return rate;
	}
	float manaRegenAt(int version_,int side,Vector3f position,ObjectState!B state){
		auto offset=Vector3f(50.0f,50.0f,0.0f);
		auto lowTile=getTile(position-offset), highTile=getTile(position+offset);
		float rate=0.0f;
		if(lowTile.j+offMapSlack<0||lowTile.i+offMapSlack<0||highTile.j+offMapSlack>=size||highTile.i+offMapSlack>=size)
			rate+=offMap.manaRegenAt(version_,side,position,state);
		foreach(j;max(0,lowTile.j+offMapSlack)..min(highTile.j+offMapSlack+1,size))
			foreach(i;max(0,lowTile.i+offMapSlack)..min(highTile.i+offMapSlack+1,size))
				rate+=data[j][i].manaRegenAt(version_,side,position,state);
		return rate;
	}
}

struct CenterProximityEntry{
	bool isStatic;
	int id;
	int side;
	Vector3f position;
	int attackTargetId=0;
	bool zeroHealth; // this information only computed for buildings at the moment
}

struct CenterProximityEntries{
	int version_=0;
	Array!CenterProximityEntry entries; // TODO: be more clever here?
	void insert(int version_,CenterProximityEntry entry){
		if(this.version_!=version_){
			entries.length=0;
			this.version_=version_;
		}
		entries~=entry;
	}
}
auto eachInRange(alias f,T...)(ref CenterProximityEntries proximity,int version_,Vector3f position,float range,T args){
	if(proximity.version_!=version_){
		proximity.entries.length=0;
		proximity.version_=version_;
	}
	foreach(ref entry;proximity.entries){
		if((entry.position-position).lengthsqr>range^^2) continue;
		f(entry,args);
	}
}

struct CenterProximity(B){
	enum resolution=50;
	enum offMapSlack=100/resolution;
	enum size=(2560+resolution-1)/resolution+2*offMapSlack;
	static Tuple!(int,"j",int,"i") getTile(Vector3f position){
		return tuple!("j","i")(cast(int)(position.y/resolution),cast(int)(position.x/resolution)); // TODO: good resolution?
	}
	CenterProximityEntries[size][size] data;
	CenterProximityEntries offMap;
	void insert(int version_,CenterProximityEntry entry){
		auto tile=getTile(entry.position);
		if(tile.j+offMapSlack<0||tile.i+offMapSlack<0||tile.j+offMapSlack>=size||tile.i+offMapSlack>=size) offMap.insert(version_,entry);
		else data[tile.j+offMapSlack][tile.i+offMapSlack].insert(version_,entry);
	}
}
auto eachInRange(alias f,B,T...)(ref CenterProximity!B proximity,int version_,Vector3f position,float range,T args){
	with(proximity){
		auto offset=Vector3f(0.5f*range,0.5f*range,0.0f);
		auto lowTile=getTile(position-offset), highTile=getTile(position+offset);
		float rate=0.0f;
		if(lowTile.j+offMapSlack<0||lowTile.i+offMapSlack<0||highTile.j+offMapSlack>=size||highTile.i+offMapSlack>=size)
			offMap.eachInRange!f(version_,position,range,args);
		foreach(j;max(0,lowTile.j+offMapSlack)..min(highTile.j+offMapSlack+1,size))
			foreach(i;max(0,lowTile.i+offMapSlack)..min(highTile.i+offMapSlack+1,size))
				data[j][i].eachInRange!f(version_,position,range,args);
		return rate;
	}
}
private static struct None;
CenterProximityEntry inRangeAndClosestTo(alias f,alias priority=None,B,T...)(ref CenterProximity!B proximity,int version_,Vector3f position,float range,Vector3f targetPosition,T args){
	enum hasPriority=!is(priority==None);
	struct State{
		auto entry=CenterProximityEntry.init;
		static if(hasPriority) int prio;
		auto distancesqr=double.infinity;
	}
	static void process(ref CenterProximityEntry entry,Vector3f targetPosition,State* state,T args){
		if(!f(entry,args)) return;
		auto distancesqr=(entry.position-targetPosition).lengthsqr;
		bool better=distancesqr<state.distancesqr;
		static if(hasPriority){
			auto prio=priority(entry,args);
			better=prio>state.prio||prio==state.prio&&better;
		}
		if(better){
			state.entry=entry;
			state.distancesqr=distancesqr;
		}
	}
	State state;
	proximity.eachInRange!process(version_,position,range,targetPosition,&state,args);
	return state.entry;
}
CenterProximityEntry closestInRange(alias f,alias priority=None,B,T...)(ref CenterProximity!B proximity,int version_,Vector3f position,float range,T args){
	return proximity.inRangeAndClosestTo!(f,priority)(version_,position,range,position,args);
}


enum EnemyType{
	all,
	creature,
	building,
}

final class Proximity(B){
	int version_=0;
	bool active=false;
	void start()in{
		assert(!active);
	}do{
		active=true;
	}
	void end()in{
		assert(active);
	}do{
		active=false;
		++version_;
	}
	HitboxProximity!B hitboxes;
	void insert(ProximityEntry entry)in{
		assert(active);
	}do{
		hitboxes.insert(version_,entry);
	}
	ManaProximity!B mana;
	void addManafount(Vector3f position){
		mana.addManafount(version_,position);
	}
	void addManalith(int side,Vector3f position){
		mana.addManalith(version_,side,position);
	}
	void addShrine(int side,Vector3f position){
		mana.addShrine(version_,side,position);
	}
	void addAltar(int side,Vector3f position){
		mana.addAltar(version_,side,position);
	}
	float addManahoar(int side,int id,Vector3f position,ObjectState!B state){
		return mana.addManahoar(version_,side,position,state);
	}
	float manaRegenAt(int side,Vector3f position,ObjectState!B state){
		return mana.manaRegenAt(version_,side,position,state);
	}
	CenterProximity!B centers;
	void insertCenter(CenterProximityEntry entry)in{
		assert(active);
	}do{
		centers.insert(version_,entry);
	}
	private static bool isEnemy(T...)(ref CenterProximityEntry entry,int side,EnemyType type,ObjectState!B state,T ignored){
		if(type==EnemyType.creature&&entry.isStatic) return false;
		if(type==EnemyType.building&&!entry.isStatic) return false;
		if(entry.zeroHealth) return false;
		return state.sides.getStance(side,entry.side)==Stance.enemy;
	}
	int closestEnemyInRange(int side,Vector3f position,float range,EnemyType type,ObjectState!B state){
		return centers.closestInRange!isEnemy(version_,position,range,side,type,state).id;
	}
	private static bool isPeasantShelter(ref CenterProximityEntry entry,int side,ObjectState!B state){
		if(!entry.isStatic) return false;
		if(state.sides.getStance(entry.side,side)==Stance.enemy) return false;
		return state.staticObjectById!((obj,state)=>state.buildingById!(bldg=>bldg.isPeasantShelter,()=>false)(obj.buildingId),()=>false)(entry.id,state);
	}
	int closestPeasantShelterInRange(int side,Vector3f position,float range,ObjectState!B state){
		return centers.closestInRange!isPeasantShelter(version_,position,range,side,state).id;
	}
	private static int advancePriority(ref CenterProximityEntry entry,int side,EnemyType type,ObjectState!B state,int id){
		if(entry.attackTargetId==id) return 1;
		return 0;
	}
	int closestEnemyInRangeAndClosestToPreferringAttackersOf(int side,Vector3f position,float range,Vector3f targetPosition,int id,EnemyType type,ObjectState!B state){
		return centers.inRangeAndClosestTo!(isEnemy,advancePriority)(version_,position,range,targetPosition,side,type,state,id).id;
	}
}
auto collide(alias f,B,T...)(Proximity!B proximity,Vector3f[2] hitbox,T args){
	return proximity.hitboxes.collide!(f,B,T)(proximity.version_,hitbox,args);
}

import std.random: MinstdRand0;
final class ObjectState(B){ // (update logic)
	SacMap!B map;
	Sides!B sides;
	Proximity!B proximity;
	float manaRegenAt(int side,Vector3f position){
		return proximity.manaRegenAt(side,position,this);
	}
	float sideDamageMultiplier(int attackerSide,int defenderSide){
		switch(sides.getStance(attackerSide,defenderSide)){
			case Stance.ally: return 0.5f; // TODO: option
			default: return 1.0f;
		}
	}
	this(SacMap!B map, Sides!B sides, Proximity!B proximity){
		this.map=map;
		this.sides=sides;
		this.proximity=proximity;
		sid=SideManager!B(32);
	}
	bool isOnGround(Vector3f position){
		return map.isOnGround(position);
	}
	Vector3f moveOnGround(Vector3f position,Vector3f direction){
		return map.moveOnGround(position,direction);
	}
	float getGroundHeight(Vector3f position){
		return map.getGroundHeight(position);
	}
	float getHeight(Vector3f position){
		return map.getHeight(position);
	}
	float getGroundHeightDerivative(Vector3f position,Vector3f direction){
		return map.getGroundHeightDerivative(position,direction);
	}
	Vector2f sunSkyRelLoc(Vector3f cameraPos){
		return map.sunSkyRelLoc(cameraPos);
	}
	int frame=0;
	auto rng=MinstdRand0(1); // TODO: figure out what rng to use
	int uniform(int n){
		import std.random: uniform;
		return uniform(0,n,rng);
	}
	T uniform(string bounds="[]",T)(T a,T b){
		import std.random: uniform;
		return uniform!bounds(a,b,rng);
	}
	Vector!(T,n) uniform(string bounds="[]",T,int n)(Vector!(T,n)[2] box){
		Vector!(T,n) r;
		foreach(i,ref x;r) x=this.uniform(box[0][i],box[1][i]);
		return r;
	}
	void copyFrom(ObjectState!B rhs){
		frame=rhs.frame;
		rng=rhs.rng;
		obj=rhs.obj;
		sid=rhs.sid;
	}
	void updateFrom(ObjectState!B rhs,Command!B[] frameCommands){
		copyFrom(rhs);
		update(frameCommands);
	}
	void applyCommand(Command!B command){
		if(!command.isApplicable(this)) return;
		bool success=true;
		scope(success) if(success){
			int whichClick=uniform(2);
			if(command.type.hasClickSound) playSound(command.side,commandAppliedSoundTags[whichClick],this);
			command.speakCommand(this);
		}
		static bool applyOrder(Command!B command,ObjectState!B state,bool updateFormation=false,Vector2f formationOffset=Vector2f(0.0f,0.0f)){
			bool success=false;
			assert(command.type==CommandType.setFormation||command.target.type.among(TargetType.terrain,TargetType.creature,TargetType.building));
			if(!command.creature){
				int[Formation.max+1] num;
				int numCreatures=0;
				Vector2f formationScale=Vector2f(1.0f,1.0f);
				foreach(selectedId;state.getSelection(command.side).creatureIds){
					if(!selectedId) break;
					static get(ref MovingObject!B object,ObjectState!B state){
						auto hitbox=object.sacObject.largeHitbox(Quaternionf.identity(),AnimationState.stance1,0);
						auto scale=hitbox[1].xy-hitbox[0].xy;
						return tuple(object.creatureAI.formation,scale);
					}
					auto curFormationCurScale=state.movingObjectById!(get,function Tuple!(Formation,Vector2f)(){ assert(0); })(selectedId,state);
					auto curFormation=curFormationCurScale[0],curScale=curFormationCurScale[1];
					if(curScale.x>formationScale.x) formationScale.x=curScale.x;
					if(curScale.y>formationScale.y) formationScale.y=curScale.y;
					num[curFormation]+=1;
				}
				if(!updateFormation){
					// command.formation=cast(Formation)iota(0,Formation.max+1).maxElement!(f=>num[f]); // does not work. why?
					command.formation=Formation.line;
					int maxNum=0;
					foreach(i;0..Formation.max+1)
						if(num[i]>num[command.formation])
							command.formation=cast(Formation)i;
				}
				auto selection=state.getSelection(command.side);
				auto targetScale=Vector2f(0.0f,0.0f);
				if(command.target.id!=0){
					static getScale(T)(ref T obj){
						static if(is(T==MovingObject!B)){
							auto hitbox=obj.sacObject.largeHitbox(Quaternionf.identity(),AnimationState.stance1,0);
							return hitbox[1].xy-hitbox[0].xy;
						}else static if(is(T==StaticObject!B)){
							auto hitbox=obj.hitbox;
							return 0.5f*(hitbox[1].xy-hitbox[0].xy);
						}else return 0.0f;
					}
					targetScale=state.objectById!((obj)=>getScale(obj))(command.target.id);
					if(selection.creatureIds[].canFind(command.target.id))
						state.movingObjectById!((ref obj,state)=>obj.clearOrder(state))(command.target.id,state);
				}
				auto ids=selection.creatureIds[].filter!(x=>x!=command.target.id);
				auto formationOffsets=getFormationOffsets(ids,command.type,command.formation,formationScale,targetScale);
				int i=0;
				foreach(selectedId;ids){ // TODO: for retreat command, need to loop over all creatures of that side
					scope(success) i++;
					if(!selectedId) break;
					command.creature=selectedId;
					success|=applyOrder(command,state,true,formationOffsets[i]);
				}
			}else{
				success=true;
				// TODO: add command indicators to scene
				Order ord;
				ord.command=command.type;
				ord.target=OrderTarget(command.target);
				ord.targetFacing=command.targetFacing;
				ord.formationOffset=formationOffset;
				auto color=CommandConeColor.white;
				if(command.type.among(CommandType.guard,CommandType.guardArea)) color=CommandConeColor.blue;
				else if(command.type.among(CommandType.attack,CommandType.advance)) color=CommandConeColor.red;
				Vector3f position;
				if(ord.command==CommandType.guard && ord.target.id){
					auto targetPositionTargetFacing=state.movingObjectById!((obj)=>tuple(obj.position,obj.creatureState.facing), ()=>tuple(ord.target.position,ord.targetFacing))(ord.target.id);
					auto targetPosition=targetPositionTargetFacing[0], targetFacing=targetPositionTargetFacing[1];
					position=getTargetPosition(targetPosition,targetFacing,formationOffset,state);
				}else position=ord.getTargetPosition(state);
				state.addCommandCone(CommandCone!B(command.side,color,position));
				state.movingObjectById!((ref obj,ord,state,side,updateFormation,formation,position){
					if(ord.command==CommandType.attack&&ord.target.type==TargetType.creature){
						// TODO: check whether they stick to creatures of a specific side
						if(state.movingObjectById!((obj,side,state)=>state.sides.getStance(side,obj.side)==Stance.enemy,()=>false)(ord.target.id,side,state)){
							position.z=state.getHeight(position)+position.z-state.getHeight(obj.position);
							auto target=state.proximity.closestEnemyInRange(side,position,attackDistance,EnemyType.creature,state);
							if(target) ord.target.id=target;
						}
					}
					if(updateFormation) obj.creatureAI.formation=formation;
					if(ord.command!=CommandType.setFormation) obj.order(ord,state,side);
				})(command.creature,ord,state,command.side,updateFormation,command.formation,position);
			}
			return success;
		}
		Lswitch:final switch(command.type) with(CommandType){
			case none: break; // TODO: maybe get rid of null commands

			case moveForward: this.movingObjectById!startMovingForward(command.creature,this,command.side); break;
			case moveBackward: this.movingObjectById!startMovingBackward(command.creature,this,command.side); break;
			case stopMoving: this.movingObjectById!stopMovement(command.creature,this,command.side); break;
			case turnLeft: this.movingObjectById!startTurningLeft(command.creature,this,command.side); break;
			case turnRight: this.movingObjectById!startTurningRight(command.creature,this,command.side); break;
			case stopTurning: this.movingObjectById!(.stopTurning)(command.creature,this,command.side); break;

			case clearSelection: this.clearSelection(command.side); break;
			static foreach(type;[select,selectAll,toggleSelection]){
				case type: mixin(`this.`~to!string(type))(command.side,command.creature); break Lswitch;
			}
			case automaticSelectAll: goto case selectAll;
			case automaticToggleSelection: goto case toggleSelection;
			static foreach(type;[defineGroup,addToGroup]){
			    case type: mixin(`this.`~to!string(type))(command.side,command.group); break Lswitch;
			}
			case selectGroup: success=this.selectGroup(command.side,command.group); break Lswitch;
			case automaticSelectGroup: goto case selectGroup;
			case setFormation: success=applyOrder(command,this,true); break;
			case retreat,move,guard,guardArea,attack,advance: success=applyOrder(command,this); break;
			case castSpell: success=this.movingObjectById!((ref obj,spell,target,state)=>obj.startCasting(spell,target,state),function()=>false)(command.wizard,command.spell,command.target,this);
		}
	}
	void update(Command!B[] frameCommands){
		frame+=1;
		proximity.start();
		this.eachByType!(addToProximity,false)(this);
		this.eachEffects!updateEffects(this);
		this.eachParticles!updateParticles(this);
		this.eachCommandCones!updateCommandCones(this);
		foreach(command;frameCommands)
			applyCommand(command);
		this.eachMoving!updateCreature(this);
		this.eachSoul!updateSoul(this);
		this.eachBuilding!updateBuilding(this);
		this.eachWizard!updateWizard(this);
		this.performRemovals();
		proximity.end();
	}
	ObjectManager!B obj;
	int addObject(T)(T object) if(is(T==MovingObject!B)||is(T==StaticObject!B)||is(T==Soul!B)||is(T==Building!B)){
		return obj.addObject(object);
	}
	void removeObject(int id)in{
		assert(id!=0);
	}do{
		obj.removeObject(id);
	}
	void setThresholdZ(int id,float thresholdZ)in{
		assert(id!=0);
	}do{
		obj.setThresholdZ(id,thresholdZ);
	}
	void setRenderMode(T,RenderMode mode)(int id)if(is(T==MovingObject!B)||is(T==StaticObject!B))in{
		assert(id!=0);
	}do{
		obj.setRenderMode!(T,mode)(id);
	}
	void setRenderMode(T,RenderMode mode)(int id)if(is(T==Building!B))in{
		assert(id!=0);
	}do{
		this.buildingById!((bldg,state){
			foreach(cid;bldg.componentIds)
				state.setRenderMode!(StaticObject!B,mode)(cid);
		})(id,this);
	}
	Array!int toRemove;
	void removeLater(int id)in{
		assert(id!=0);
	}do{
		toRemove~=id;
	}
	void performRemovals(){
		foreach(id;toRemove.data) removeObject(id);
		toRemove.length=0;
	}
	void addWizard(WizardInfo!B wizard){
		obj.addWizard(wizard);
	}
	WizardInfo!B* getWizard(int id){
		return obj.getWizard(id);
	}
	auto getLevel(int id){
		auto wizard=getWizard(id);
		return wizard?wizard.level:0;
	}
	auto getSpells(int id){
		return getSpells(getWizard(id));
	}
	auto getSpells(bool retro=false)(WizardInfo!B* wizard){
		static bool pred(ref SpellInfo!B spell,int level){ return spell.level<=level; }
		static bool pred2(T)(T x){ return pred(x[]); }
		static first(T)(T x){ return x[0]; }
		if(!wizard) return zip(typeof(mixin(retro?q{ wizard.getSpells().retro }:q{ wizard.getSpells()})).init,repeat(0)).filter!pred2.map!first;
		return zip(mixin(retro?q{ wizard.getSpells().retro }:q{ wizard.getSpells()}),repeat(wizard.level)).filter!pred2.map!first;
	}
	God getCurrentGod(int id){
		return getCurrentGod(getWizard(id));
	}
	God getCurrentGod(WizardInfo!B* wizard){
		if(!wizard) return God.none;
		auto spells=getSpells!true(wizard).filter!(x=>x.spell.type.among(SpellType.creature,SpellType.spell));
		if(spells.empty) return God.none;
		return spells.front.spell.god;
	}
	private static alias spellStatusArgs(bool selectOnly:true)=Seq!();
	private static alias spellStatusArgs(bool selectOnly:false)=Seq!Target;
	SpellStatus spellStatus(bool selectOnly=false)(int id,SacSpell!B spell,spellStatusArgs!selectOnly target){ // DMD bug: default argument does not work
		auto wizard=getWizard(id);
		if(!wizard) return SpellStatus.inexistent;
		return spellStatus!selectOnly(wizard,spell,target);
	}
	SpellStatus spellStatus(bool selectOnly=false)(WizardInfo!B* wizard,SacSpell!B spell,spellStatusArgs!selectOnly target){ // DMD bug: default argument does not work
		foreach(entry;wizard.getSpells()){
			if(entry.spell!is spell) continue;
			if(entry.level>wizard.level) return SpellStatus.inexistent;
			if(spell.soulCost>wizard.souls) return SpellStatus.needMoreSouls;
			if(entry.cooldown>0.0f) return SpellStatus.notReady;
			return this.movingObjectById!((obj,spell,state,spellStatusArgs!selectOnly target){
				if(spell.manaCost>obj.creatureStats.mana) return SpellStatus.lowOnMana;
				// if(spell.nearBuilding&&...) return SpellStatus.mustBeNearBuilding; // TODO
				// if(spell.nearEnemyAltar&&...) return SpellStatus.mustBeNearEnemyAltar; // TODO
				// if(spell.connectedToConversion&&....) return SpellStatus.mustBeConnectedToConversion; // TODO
				static if(!selectOnly){
					if(spell.requiresTarget&&!spell.isApplicable(summarize(target[0],obj.side,this))) return SpellStatus.invalidTarget;
					if((obj.position-target[0].position).lengthsqr>spell.range^^2) return SpellStatus.outOfRange;
				}
				return SpellStatus.ready;
			},function()=>SpellStatus.inexistent)(wizard.id,spell,this,target);
		}
		return SpellStatus.inexistent;
	}
	void removeWizard(int id){
		obj.removeWizard(id);
	}
	bool isValidId(int id){
		return obj.isValidId(id);
	}
	bool isValidId(int id,TargetType type){
		return obj.isValidId(id,type);
	}
	void addFixed(FixedObject!B object){
		obj.addFixed(object);
	}
	void addEffect(T)(T proj){
		obj.addEffect(proj);
	}
	void addParticle(Particle!B particle){
		obj.addParticle(particle);
	}
	void addCommandCone(CommandCone!B cone){
		obj.addCommandCone(cone);
	}
	SideManager!B sid;
	void clearSelection(int side){
		sid.clearSelection(side);
	}
	void select(int side,int id){
		if(!canSelect(side,id,this)) return;
		sid.select(side,id);
	}
	void selectAll(int side,int id){
		if(!canSelect(side,id,this)) return;
		// TODO: use Proximity for this? (Not a bottleneck.)
		static void processObj(B)(MovingObject!B obj,int side,ObjectState!B state){
			struct MObj{ int id; Vector3f position; }
			alias Selection=MObj[numCreaturesInGroup];
			Selection selection;
			static void addToSelection(ref MObj[numCreaturesInGroup] selection,MObj obj,MObj nobj){
				if(selection[].map!"a.id".canFind(nobj.id)) return;
				int i=0;
				while(i<selection.length&&selection[i].id&&(selection[i].position.xy-obj.position.xy).lengthsqr<(nobj.position.xy-obj.position.xy).lengthsqr)
					i++;
				if(i>=selection.length||selection[i].id==nobj.id) return;
				foreach_reverse(j;i..selection.length-1)
					swap(selection[j],selection[j+1]);
				selection[i]=nobj;
			}
			static void process(B)(MovingObject!B nobj,int side,MObj obj,Selection* selection,ObjectState!B state){
				if(!canSelect(nobj,side,state)) return;
				if((obj.position.xy-nobj.position.xy).lengthsqr>50.0f^^2) return;
				addToSelection(*selection,obj,MObj(nobj.id,nobj.position));
			}
			state.eachMovingOf!process(obj.sacObject,side,MObj(obj.id,obj.position),&selection,state);
			if(selection[0].id!=0){
				state.clearSelection(side);
				foreach_reverse(i;0..selection.length)
					if(selection[i].id) state.sid.addToSelection(side,selection[i].id);
			}
		}
		this.movingObjectById!processObj(id,side,this);
	}
	void addToSelection(int side,int id){
		if(!canSelect(side,id,this)) return;
		sid.addToSelection(side,id);
	}
	void removeFromSelection(int side,int id){
		if(!canSelect(side,id,this)) return;
		sid.removeFromSelection(side,id);
	}
	void toggleSelection(int side,int id){
		if(!canSelect(side,id,this)) return;
		sid.toggleSelection(side,id);
	}
	void defineGroup(int side,int groupId){
		sid.defineGroup(side,groupId);
	}
	void addToGroup(int side,int groupId){
		sid.addToGroup(side,groupId);
	}
	bool selectGroup(int side,int groupId){
		return sid.selectGroup(side,groupId);
	}
	void removeFromGroups(int side,int id){
		if(!canSelect(side,id,this)) return;
		sid.removeFromGroups(side,id);
	}
	CreatureGroup getSelection(int side){
		return sid.getSelection(side);
	}
	int[2] lastSelected(int side){
		return sid.lastSelected(side);
	}
	void resetSelectionCount(int side){
		return sid.resetSelectionCount(side);
	}
	int getSelectionRepresentative(int side){
		auto ids=getSelection(side).creatureIds;
		int result=0,bestPriority=-1;
		foreach(id;ids){
			if(id){
				int priority=this.movingObjectById!((obj)=>obj.sacObject.creaturePriority,()=>-1)(id);
				if(priority>bestPriority){
					result=id;
					bestPriority=priority;
				}
			}
		}
		return result;
	}
}
auto each(alias f,B,T...)(ObjectState!B objectState,T args){
	return objectState.obj.each!f(args);
}
auto eachMoving(alias f,B,T...)(ObjectState!B objectState,T args){
	return objectState.obj.eachMoving!f(args);
}
auto eachStatic(alias f,B,T...)(ObjectState!B objectState,T args){
	return objectState.obj.eachStatic!f(args);
}
auto eachSoul(alias f,B,T...)(ObjectState!B objectState,T args){
	return objectState.obj.eachSoul!f(args);
}
auto eachBuilding(alias f,B,T...)(ObjectState!B objectState,T args){
	return objectState.obj.eachBuilding!f(args);
}
auto eachWizard(alias f,B,T...)(ObjectState!B objectState,T args){
	return objectState.obj.eachWizard!f(args);
}
auto eachEffects(alias f,B,T...)(ObjectState!B objectState,T args){
	return objectState.obj.eachEffects!f(args);
}
auto eachParticles(alias f,B,T...)(ObjectState!B objectState,T args){
	return objectState.obj.eachParticles!f(args);
}
auto eachCommandCones(alias f,B,T...)(ObjectState!B objectState,T args){
	return objectState.obj.eachCommandCones!f(args);
}
auto eachByType(alias f,bool movingFirst=true,B,T...)(ObjectState!B objectState,T args){
	return objectState.obj.eachByType!(f,movingFirst)(args);
}
auto eachMovingOf(alias f,B,T...)(ObjectState!B objectState,SacObject!B sacObject,T args){
	return objectState.obj.eachMovingOf!f(sacObject,args);
}

auto ref objectById(alias f,B,T...)(ObjectState!B objectState,int id,T args){
	return objectState.obj.objectById!f(id,args);
}
auto ref movingObjectById(alias f,alias nonMoving=fail,B,T...)(ObjectState!B objectState,int id,T args){
	return objectState.obj.movingObjectById!(f,nonMoving)(id,args);
}
auto ref staticObjectById(alias f,alias nonStatic=fail,B,T...)(ObjectState!B objectState,int id,T args){
	return objectState.obj.staticObjectById!(f,nonStatic)(id,args);
}
auto ref soulById(alias f,alias noSoul=fail,B,T...)(ObjectState!B objectState,int id,T args){
	return objectState.obj.soulById!(f,noSoul)(id,args);
}
auto ref buildingById(alias f,alias noBuilding=fail,B,T...)(ObjectState!B objectState,int id,T args){
	return objectState.obj.buildingById!(f,noBuilding)(id,args);
}
auto ref buildingByStaticObjectId(alias f,alias noStatic=fail,B,T...)(ObjectState!B objectState,int id,T args){
	return objectState.obj.buildingByStaticObjectId!(f,noStatic)(id,args);
}

enum Stance{
	neutral,
	ally,
	enemy,
}

final class Sides(B){
	private Side[32] sides;
	private SacParticle!B[32] manaParticles;
	private SacParticle!B[32] shrineParticles;
	private SacParticle!B[32] manahoarParticles;
	this(Side[] sids...){
		foreach(ref side;sids){
			enforce(0<=side.id&&side.id<32);
			sides[side.id]=side;
		}
		foreach(i;0..32){
			sides[i].allies|=(1<<i); // allied to themselves
			sides[i].enemies&=~(1<<i); // not enemies of themselves
		}
	}
	Color4f sideColor(int side){
		auto c=sideColors[sides[side].color];
		if(side==31) static foreach(i;0..3) c[i]*=0.5f;
		return c;
	}
	Color4f manaColor(int side){
		auto color=0.8f*Vector3f(sideColor(side).rgb)+0.2f*Vector3f(1.0f,1.0f,1.0f);
		auto total=color.r+color.g+color.b;
		return Color4f((3.0f/total)*color);
	}
	float manaEnergy(int side){
		auto color=sideColor(side);
		if(color.g<0.15f) return 160.0f;
		return 20.0f;
	}
	SacParticle!B manaParticle(int side){
		if(!manaParticles[side]) manaParticles[side]=new SacParticle!B(ParticleType.manalith, manaColor(side), manaEnergy(side));
		return manaParticles[side];
	}
	SacParticle!B shrineParticle(int side){
		if(!shrineParticles[side]) shrineParticles[side]=new SacParticle!B(ParticleType.shrine, manaColor(side), manaEnergy(side));
		return shrineParticles[side];
	}
	SacParticle!B manahoarParticle(int side){
		if(!manahoarParticles[side]) manahoarParticles[side]=new SacParticle!B(ParticleType.manahoar, manaColor(side), manaEnergy(side));
		return manahoarParticles[side];
	}
	Stance getStance(int from,int towards){
		if(sides[from].allies&(1<<towards)) return Stance.ally;
		if(sides[from].enemies&(1<<towards)) return Stance.enemy;
		return Stance.neutral;
	}
}

enum numCreatureGroups=10;
enum numCreaturesInGroup=12;
struct CreatureGroup{
	int[numCreaturesInGroup] creatureIds;
	int[] get(){ return creatureIds[]; }
	bool has(int id){
		if(!id) return false;
		foreach(x;creatureIds) if(x==id) return true;
		return false;
	}
	void addFront(int id){ // for addToSelection
		if(!id) return;
		if(has(id)) return;
		foreach_reverse(i;0..creatureIds.length-1)
			swap(creatureIds[i],creatureIds[i+1]);
		creatureIds[0]=id;
	}
	void addBack(int id){ // for addToGroup
		if(!id) return;
		if(has(id)) return;
		if(creatureIds[$-1]){
			foreach(i;0..creatureIds.length-1)
				swap(creatureIds[i],creatureIds[i+1]);
			creatureIds[$-1]=id;
		}else{
			foreach_reverse(i;-1..cast(int)creatureIds.length-1){
				if(i==-1||creatureIds[i]){
					creatureIds[i+1]=id;
					break;
				}
			}
		}
	}
	void addSorted(int id){
		if(!id) return;
		if(has(id)) return;
		int i=0;
		while(i<creatureIds.length&&creatureIds[i]&&creatureIds[i]>id)
			i++;
		if(i>=creatureIds.length||creatureIds[i]==id) return;
		foreach_reverse(j;i..creatureIds.length-1)
			swap(creatureIds[j],creatureIds[j+1]);
		creatureIds[i]=id;
	}
	void addFront(int[] ids...){
		foreach_reverse(id;ids) addFront(id); // TODO: do more efficiently
	}
	void addBack(int[] ids...){
		foreach(id;ids) addBack(id); // TODO: do more efficiently
	}
	void remove(int id){
		if(!id) return;
		foreach(i,x;creatureIds){
			if(x==id){
				foreach(j;i..creatureIds.length-1){
					swap(creatureIds[j],creatureIds[j+1]);
				}
				assert(creatureIds[$-1]==id);
				creatureIds[$-1]=0;
			}
		}
	}
	bool toggle(int id){
		if(!id) return false;
		if(has(id)){
			remove(id);
			return false;
		}else{
			addFront(id);
			return true;
		}
	}
	void clear(){
		creatureIds[]=0;
	}
}

struct SideData(B){
	CreatureGroup selection;
	CreatureGroup[10] groups;
	int lastSelected=0;
	int selectionMultiplicity=0;
	void updateLastSelected(int id){
		if(lastSelected!=id){
			lastSelected=id;
			selectionMultiplicity=1;
		}else selectionMultiplicity++;
	}
	void clearSelection(){
		selection.clear();
	}
	void select(int id){
		clearSelection();
		selection.addFront(id);
		updateLastSelected(id);
	}
	void addToSelection(int id){
		if(selection.has(id)) return;
		selection.addFront(id);
	}
	void removeFromSelection(int id){
		selection.remove(id);
	}
	void toggleSelection(int id){
		if(selection.toggle(id))
			updateLastSelected(id);
	}
	void defineGroup(int groupId)in{
		assert(0<=groupId&&groupId<numCreatureGroups);
	}do{
		groups[groupId]=selection;
	}
	void addToGroup(int groupId){
		groups[groupId].addBack(selection.creatureIds[]);
	}
	bool selectGroup(int groupId){
		if(groups[groupId].creatureIds[0]==0) return false;
		selection=groups[groupId];
		return true;
	}
	void removeFromGroups(int id){
		removeFromSelection(id);
		foreach(i;0..groups.length)
			groups[i].remove(id);
	}
	CreatureGroup getSelection(){
		return selection;
	}
	void resetSelectionCount(){
		selectionMultiplicity=0;
	}
}

struct SideManager(B){
	Array!(SideData!B) sides;
	this(int numSides){
		sides.length=numSides;
	}
	void opAssign(SideManager!B rhs){
		assignArray(sides,rhs.sides);
	}
	void clearSelection(int side)in{
		assert(0<=side&&side<sides.length);
	}do{
		sides[side].clearSelection();
	}
	void select(int side,int id)in{
		assert(0<=side&&side<sides.length&&id);
	}do{
		sides[side].select(id);
	}
	void addToSelection(int side,int id)in{
		assert(0<=side&&side<sides.length&&id);
	}do{
		sides[side].addToSelection(id);
	}
	void removeFromSelection(int side,int id)in{
		assert(0<=side&&side<sides.length&&id);
	}do{
		sides[side].removeFromSelection(id);
	}
	void toggleSelection(int side,int id)in{
		assert(0<=side&&side<sides.length&&id);
	}do{
		sides[side].toggleSelection(id);
	}
	void defineGroup(int side,int groupId)in{
		assert(0<=side&&side<sides.length&&0<=groupId&&groupId<numCreatureGroups);
	}do{
		sides[side].defineGroup(groupId);
	}
	void addToGroup(int side,int groupId)in{
		assert(0<=side&&side<sides.length&&0<=groupId&&groupId<numCreatureGroups);
	}do{
		sides[side].addToGroup(groupId);
	}
	bool selectGroup(int side,int groupId)in{
		assert(0<=side&&side<sides.length&&0<=groupId&&groupId<numCreatureGroups);
	}do{
		return sides[side].selectGroup(groupId);
	}
	void removeFromGroups(int side,int id)in{
		assert(0<=side&&side<sides.length&&id);
	}do{
		sides[side].removeFromGroups(id);
	}
	CreatureGroup getSelection(int side)in{
		assert(0<=side&&side<sides.length);
	}do{
		return sides[side].getSelection();
	}
	int[2] lastSelected(int side)in{
		assert(0<=side&&side<sides.length);
	}do{
		return [sides[side].lastSelected,sides[side].selectionMultiplicity];
	}
	void resetSelectionCount(int side)in{
		assert(0<=side&&side<sides.length);
	}do{
		return sides[side].resetSelectionCount();
	}
}

final class Triggers(B){
	int[int] objectIds;
	void associateId(int triggerId,int objectId)in{
		assert(triggerId !in objectIds);
	}do{
		objectIds[triggerId]=objectId;
	}
}

enum TargetType{
	none,
	terrain,
	creature,
	building,
	soul,

	creatureTab,
	spellTab,
	structureTab,

	spell,

	soulStat,
	manaStat,
	healthStat,
}

enum TargetLocation{
	none,
	scene,
	minimap,
	selectionRoster,
	spellbook,
	hud,
}

struct Target{
	TargetType type;
	int id;
	Vector3f position;
	auto location=TargetLocation.scene;
}
TargetFlags summarize(bool simplified=false,B)(ref Target target,int side,ObjectState!B state){
	final switch(target.type) with(TargetType){
		case none,creatureTab,spellTab,structureTab,spell,soulStat,manaStat,healthStat: return TargetFlags.none;
		case terrain: return TargetFlags.ground;
		case creature,building:
			static TargetFlags handle(T)(T obj,int side,ObjectState!B state){
				enum isMoving=is(T==MovingObject!B);
				static if(isMoving){
					auto result=TargetFlags.creature;
					if(obj.creatureState.mode==CreatureMode.dead) result|=TargetFlags.corpse;
					auto objSide=obj.side;
				}else{
					auto result=TargetFlags.building;
					auto objSide=sideFromBuildingId(obj.buildingId,state);
					auto buildingInterestingIsManafountTop=state.buildingById!(bldg=>tuple(bldg.health!=0||bldg.isAltar,bldg.isManafount,bldg.top),()=>tuple(false,false,0))(obj.buildingId);
					auto buildingInteresting=buildingInterestingIsManafountTop[0],isManafount=buildingInterestingIsManafountTop[1],top=buildingInterestingIsManafountTop[2];
					buildingInteresting|=isManafount;
					if(!buildingInteresting) result|=TargetFlags.untargetable; // TODO: there might be a flag for this
					if(isManafount&&!top) result|=TargetFlags.manafount;
				}
				if(objSide!=side){
					auto stance=state.sides.getStance(side,objSide);
					final switch(stance){
						case Stance.neutral: break;
						case Stance.ally: result|=TargetFlags.ally; break;
						case Stance.enemy: result|=TargetFlags.enemy; break;
					}
					static if(isMoving) if(stance!=Stance.enemy&&obj.creatureStats.flags&Flags.rescuable) result|=TargetFlags.rescuable;
				}else result|=TargetFlags.owned|TargetFlags.ally;
				static if(isMoving&&!simplified){
					enum flyingLimit=1.0f; // TODO: measure this.
					if(!state.isOnGround(obj.position)||obj.hitbox[0].z>=state.getGroundHeight(obj.position)+flyingLimit) result|=TargetFlags.flying;
					if(obj.isWizard){
						result&=~TargetFlags.creature;
						result|=TargetFlags.wizard;
					}
					// TODO: shield/hero
				}
				return result;
			}
			return state.objectById!handle(target.id,side,state);
		case soul:
			auto result=TargetFlags.soul;
			auto objSide=soulSide(target.id,state);
			if(objSide==-1||objSide==side) result|=TargetFlags.owned|TargetFlags.ally; // TODO: ok? (not exactly what is going on with free souls.)
			else result|=TargetFlags.enemy;
			return result;
	}
}
Cursor cursor(B)(ref Target target,int renderSide,bool showIcon,ObjectState!B state){
	auto summary=summarize!true(target,renderSide,state);
	with(TargetFlags) with(Cursor){
		if(summary==none) return showIcon?iconNone:normal;
		if(summary&ground||summary&corpse||summary&untargetable) return showIcon?iconNeutral:normal;
		if(summary&owned){
			if(summary&creature) return showIcon?iconFriendly:friendlyUnit;
			if(summary&building) return showIcon?iconFriendly:friendlyBuilding;
		}
		bool isNeutral=!(summary&enemy);
		if(summary&creature){
			if(isNeutral) return showIcon?iconNeutral:(summary&rescuable?rescuableUnit:neutralUnit);
			return showIcon?iconEnemy:enemyUnit;
		}
		if(summary&building){
			if(isNeutral) return showIcon?iconNeutral:(summary&manafount?normal:neutralBuilding);
			return showIcon?iconEnemy:enemyBuilding;
		}
		if(summary&soul){
			if(summary&owned) return showIcon?iconNone:blueSoul;
			return showIcon?iconNone:normal;
		}
		return showIcon?iconNone:normal;
	}
}


enum CommandType{
	none,
	moveForward,
	moveBackward,
	stopMoving,
	turnLeft,
	turnRight,
	stopTurning,

	clearSelection,
	select,
	selectAll,
	automaticSelectAll,
	toggleSelection,
	automaticToggleSelection,

	defineGroup,
	addToGroup,
	selectGroup,
	automaticSelectGroup,

	setFormation,

	retreat,
	move,
	guard,
	guardArea,
	attack,
	advance,

	castSpell,
}

bool hasClickSound(CommandType type){
	final switch(type) with(CommandType){
		case none,moveForward,moveBackward,stopMoving,turnLeft,turnRight,stopTurning,clearSelection,automaticToggleSelection,automaticSelectGroup,setFormation,retreat: return false;
		case select,selectAll,automaticSelectAll,toggleSelection,defineGroup,addToGroup,selectGroup,move,guard,guardArea,attack,advance,castSpell: return true;
	}
}
SoundType soundType(B)(Command!B command){
	final switch(command.type) with(CommandType){
		case none,moveForward,moveBackward,stopMoving,turnLeft,turnRight,stopTurning,clearSelection,select,selectAll,automaticSelectAll,toggleSelection,automaticToggleSelection,automaticSelectGroup:
			return SoundType.none;
		case defineGroup,addToGroup:
			switch(command.group){
				static foreach(i;0..10) case i: return mixin(`SoundType.beGroup`~to!string(i+1));
				default: return SoundType.none;
			}
		case selectGroup:
			switch(command.group){
				static foreach(i;0..10) case i: return mixin(`SoundType.group`~to!string(i+1));
				default: return SoundType.none;
			}
		case setFormation:
			final switch(command.formation) with(Formation){
				case line: return SoundType.lineFormation;
				case flankLeft: return SoundType.none;
				case flankRight: return SoundType.none;
				case phalanx: return SoundType.phalanxFormation;
				case semicircle: return SoundType.semicircleFormation;
				case circle: return SoundType.circleFormation;
				case wedge: return SoundType.wedgeFormation;
				case skirmish: return SoundType.skirmishFormation;
			}
		case retreat: return SoundType.guardMe;
		case move: return SoundType.move;
		case guard: return command.target.type==TargetType.building?SoundType.guardBuilding:command.wizard==command.target.id?SoundType.guardMe:SoundType.guard;
		case guardArea: return SoundType.defendArea;
		case attack: return command.target.type==TargetType.building?SoundType.attackBuilding:SoundType.attack;
		case advance: return SoundType.advance;
		case castSpell: return SoundType.none;
	}
}
SoundType responseSoundType(B)(Command!B command){
	final switch(command.type) with(CommandType){
		case none,moveForward,moveBackward,stopMoving,turnLeft,turnRight,stopTurning,setFormation,clearSelection,automaticSelectAll,automaticToggleSelection,defineGroup,addToGroup,automaticSelectGroup,retreat,castSpell:
			return SoundType.none;
		case select,selectAll,toggleSelection,selectGroup:
			return SoundType.selected;
		case move,guard,guardArea: return SoundType.moving;
		case attack,advance: return SoundType.attacking;
	}
}
void speakCommand(B)(Command!B command,ObjectState!B state){
	if(!command.wizard) return;
	auto soundType=command.soundType;
	if(soundType!=SoundType.none){
		auto sacObject=state.movingObjectById!((obj)=>obj.sacObject,()=>null)(command.wizard);
		if(sacObject) queueDialogSound(command.side,sacObject,soundType,DialogPriority.command,state);
	}
	auto responseSoundType=command.responseSoundType;
	if(responseSoundType!=SoundType.none){
		int responding=command.creature?command.creature:state.getSelectionRepresentative(command.side);
		if(responding&&state.getSelection(command.side).creatureIds[].canFind(responding)){
			if(auto respondingSacObject=state.movingObjectById!((obj)=>obj.sacObject,()=>null)(responding)){
				if(responseSoundType==SoundType.selected){
					auto lastSelected=state.lastSelected(command.side);
					if(responding==lastSelected[0]&&lastSelected[1]>3){
						if(auto sset=respondingSacObject.sset){
							auto sounds=sset.getSounds(SoundType.annoyed);
							auto sound=sounds[(lastSelected[1]-4)%$];
							static if(B.hasAudio) if(playAudio)
								B.queueDialogSound(command.side,sound,DialogPriority.annoyedResponse);
							return;
						}
					}
				}else state.resetSelectionCount(command.side);
				queueDialogSound(command.side,respondingSacObject,responseSoundType,DialogPriority.response,state);
			}
		}
	}
}
// TODO: get rid of duplicated code
enum DialogPriority{
	response,
	annoyedResponse,
	command,
	advisorAnnoy,
	advisorImportant,
}
enum DialogPolicy{
	queue,
	interruptPrevious,
	ignorePrevious,
	ignoreCurrent,
}
DialogPolicy dialogPolicy(DialogPriority previous,DialogPriority current){
	with(DialogPriority) with(DialogPolicy){
		if(previous.among(response,annoyedResponse)) return previous<current?interruptPrevious:queue;
		if(previous==command) return previous==current?ignorePrevious:previous<current?interruptPrevious:queue;
		return previous<current?interruptPrevious:current==advisorAnnoy?ignoreCurrent:queue;
	}
}
void queueDialogSound(B)(int side,SacObject!B sacObject,SoundType soundType,DialogPriority priority,ObjectState!B state){
	void playSset(immutable(Sset)* sset){
		auto sounds=sset.getSounds(soundType);
		if(sounds.length){
			auto sound=sounds[state.uniform(cast(int)$)];
			static if(B.hasAudio) if(playAudio)
				B.queueDialogSound(side,sound,priority);
		}
	}
	if(auto sset=sacObject.sset) playSset(sset);
	if(auto sset=sacObject.meleeSset) playSset(sset);
}
int getSoundDuration(B)(char[4] sound,ObjectState!B state){
	return B.getSoundDuration(sound);
}
void playSound(B)(int side,char[4] sound,ObjectState!B state,float gain=1.0f){
	static if(B.hasAudio) if(playAudio) B.playSound(side,sound,gain);
}
void playSoundType(B)(int side,SacObject!B sacObject,SoundType soundType,ObjectState!B state){
	void playSset(immutable(Sset)* sset){
		auto sounds=sset.getSounds(soundType);
		if(sounds.length){
			auto sound=sounds[state.uniform(cast(int)$)];
			playSound(side,sound,state);
		}
	}
	if(auto sset=sacObject.sset) playSset(sset);
	if(auto sset=sacObject.meleeSset) playSset(sset);
}
void playSoundAt(B)(char[4] sound,Vector3f position,ObjectState!B state,float gain=1.0f){
	static if(B.hasAudio) if(playAudio) B.playSoundAt(sound,position,gain);
}
auto playSoundAt(bool getDuration=false,B,T...)(char[4] sound,int id,ObjectState!B state,float gain=1.0f){
	static if(B.hasAudio) if(playAudio) B.playSoundAt(sound,id,gain);
	static if(getDuration) return getSoundDuration(sound,state);
}
auto playSoundTypeAt(bool getDuration=false,B,T...)(SacObject!B sacObject,int id,SoundType soundType,ObjectState!B state,T limit)if(T.length<=(getDuration?1:0)){
	static if(getDuration) int duration=0;
	void playSset(immutable(Sset)* sset){
		auto sounds=sset.getSounds(soundType);
		if(sounds.length){
			auto sound=sounds[state.uniform(cast(int)$)];
			auto gain=sset.name=="wasb"?2.0f:1.0f;
			static if(getDuration){
				auto soundDuration=getSoundDuration(sound,state);
				static if(limit.length) if(soundDuration>limit[0]) return;
				duration=max(duration,soundDuration);
			}
			playSoundAt(sound,id,state,gain);
		}
	}
	if(auto sset=sacObject.sset) playSset(sset);
	if(auto sset=sacObject.meleeSset) playSset(sset);
	static if(getDuration) return duration;
}
auto stopSoundsAt(B)(int id,ObjectState!B state){
	static if(B.hasAudio) if(playAudio) B.stopSoundsAt(id);
}
struct Command(B){
	this(CommandType type,int side,int wizard,int creature,Target target,float targetFacing)in{
		final switch(type) with(CommandType){
			case none:
				assert(0);
			case moveForward,moveBackward,stopMoving,turnLeft,turnRight,stopTurning:
				assert(!!creature && target is Target.init);
				break;
			case clearSelection:
				assert(!creature && target is Target.init);
				break;
			case select,selectAll,automaticSelectAll,toggleSelection,automaticToggleSelection:
				assert(creature && target is Target.init);
				break;
			case move:
				assert(target.type==TargetType.terrain);
				break;
			case setFormation:
				assert(0);
			case retreat:
				assert(target.type==TargetType.creature);
				break;
			case guard,attack:
				assert(target.type.among(TargetType.creature,TargetType.building));
				break;
			case guardArea,advance:
				assert(target.type==TargetType.terrain);
				break;
				case defineGroup,addToGroup,selectGroup,automaticSelectGroup:
				assert(0);
			case castSpell:
				assert(0);
		}
	}do{
		this.type=type;
		this.side=side;
		this.wizard=wizard;
		this.creature=creature;
		this.target=target;
		this.targetFacing=targetFacing;
	}

	this(CommandType type,int side,int wizard,int group)in{
		switch(type) with(CommandType){
			case defineGroup,addToGroup,selectGroup,automaticSelectGroup:
				assert(0<=group && group<10);
				break;
			default:
				assert(0);
		}
	}do{
		this.type=type;
		this.side=side;
		this.wizard=wizard;
		this.group=group;
	}

	this(int side,int wizard,Formation formation){
		this.type=CommandType.setFormation;
		this.side=side;
		this.wizard=wizard;
		this.formation=formation;
	}

	this(B)(int side,int wizard,SacSpell!B spell,Target target){
		this.type=CommandType.castSpell;
		this.side=side;
		this.wizard=wizard;
		this.spell=spell;
		this.target=target;
	}

	CommandType type;
	int side;
	int wizard;
	int creature;
	SacSpell!B spell;
	Target target;
	float targetFacing;
	Formation formation=Formation.init;
	int group=-1;

	bool isApplicable(B)(ObjectState!B state){
		return (wizard==0||state.isValidId(wizard,TargetType.creature)) &&
			(creature==0||state.isValidId(creature,TargetType.creature)) &&
			(target.id==0&&target.type.among(TargetType.none,TargetType.terrain)||state.isValidId(target.id,target.type));
	}
}

bool playAudio=true;
final class GameState(B){
	ObjectState!B lastCommitted;
	ObjectState!B current;
	ObjectState!B next;
	Triggers!B triggers;
	Array!(Array!(Command!B)) commands;
	this(SacMap!B map,Side[] sids,NTTs ntts,Options options)in{
		assert(!!map);
	}body{
		auto sides=new Sides!B(sids);
		auto proximity=new Proximity!B();
		current=new ObjectState!B(map,sides,proximity);
		next=new ObjectState!B(map,sides,proximity);
		lastCommitted=new ObjectState!B(map,sides,proximity);
		triggers=new Triggers!B();
		commands.length=1;
		foreach(ref structure;ntts.structures)
			placeStructure(structure);
		foreach(ref wizard;ntts.wizards)
			placeNTT(wizard);
		foreach(ref spirit;ntts.spirits)
			placeSpirit(spirit);
		foreach(ref creature;ntts.creatures)
			foreach(k;0..options.replicateCreatures) placeNTT(creature);
		foreach(widgets;ntts.widgetss) // TODO: improve engine to be able to handle this
			placeWidgets(widgets);
		current.eachMoving!((ref MovingObject!B object, ObjectState!B state){
			if(object.creatureState.mode==CreatureMode.dead) object.createSoul(state);
		})(current);
		map.meshes=createMeshes!B(map.edges,map.heights,map.tiles,options.enableMapBottom); // TODO: allow dynamic retexuring
		map.minimapMeshes=createMinimapMeshes!B(map.edges,map.tiles);
		commit();
	}
	void placeStructure(ref Structure ntt){
		import nttData;
		auto data=ntt.tag in bldgs;
		enforce(!!data);
		auto flags=ntt.flags&~Flags.damaged&~ntt.flags.destroyed;
		auto facing=2*cast(float)PI/360.0f*ntt.facing;
		auto buildingId=current.addObject(Building!B(data,ntt.side,flags,facing));
		if(ntt.id !in triggers.objectIds) // e.g. for some reason, the two altars on ferry have the same id
			triggers.associateId(ntt.id,buildingId);
		auto position=Vector3f(ntt.x,ntt.y,ntt.z);
		auto ci=cast(int)(position.x/10+0.5);
		auto cj=cast(int)(position.y/10+0.5);
		import bldg;
		if(data.flags&BldgFlags.ground){
			auto ground=data.ground;
			auto n=current.map.n,m=current.map.m;
			foreach(j;max(0,cj-4)..min(n,cj+4)){
				foreach(i;max(0,ci-4)..min(m,ci+4)){
					auto dj=j-(cj-4), di=i-(ci-4);
					if(ground[dj][di])
						current.map.tiles[j][i]=ground[dj][di];
				}
			}
		}
		current.buildingById!((ref Building!B building){
			if(ntt.flags&Flags.damaged) building.health/=10.0f;
			if(ntt.flags&Flags.destroyed) building.health=0.0f;
			foreach(ref component;data.components){
				auto curObj=SacObject!B.getBLDG(ntt.flags&Flags.destroyed&&component.destroyed!="\0\0\0\0"?component.destroyed:component.tag);
				auto offset=Vector3f(component.x,component.y,component.z);
				offset=rotate(facingQuaternion(building.facing), offset);
				auto cposition=position+offset;
				if(!current.isOnGround(cposition)) continue;
				cposition.z=current.getGroundHeight(cposition);
				auto rotation=facingQuaternion(2*cast(float)PI/360.0f*(ntt.facing+component.facing));
				building.componentIds~=current.addObject(StaticObject!B(curObj,building.id,cposition,rotation));
			}
			if(ntt.base){
				enforce(ntt.base in triggers.objectIds);
				current.buildingById!((ref manafount,state){ putOnManafount(building,manafount,state); })(triggers.objectIds[ntt.base],current);
			}
			building.loopingSoundSetup(current);
		})(buildingId);
	}

	void placeNTT(T)(ref T ntt) if(is(T==Creature)||is(T==Wizard)){
		auto curObj=SacObject!B.getSAXS!T(ntt.tag);
		auto position=Vector3f(ntt.x,ntt.y,ntt.z);
		bool onGround=current.isOnGround(position);
		if(onGround)
			position.z=current.getGroundHeight(position);
		auto rotation=facingQuaternion(ntt.facing);
		auto mode=ntt.flags & Flags.corpse ? CreatureMode.dead : CreatureMode.idle;
		auto movement=curObj.mustFly?CreatureMovement.flying:CreatureMovement.onGround;
		if(movement==CreatureMovement.onGround && !onGround)
			movement=curObj.canFly?CreatureMovement.flying:CreatureMovement.tumbling;
		auto creatureState=CreatureState(mode, movement, ntt.facing);
		auto obj=MovingObject!B(curObj,position,rotation,AnimationState.stance1,0,creatureState,curObj.creatureStats(ntt.flags),ntt.side);
		obj.setCreatureState(current);
		obj.updateCreaturePosition(current);
		/+do{
			import std.random: uniform;
			state=cast(AnimationState)uniform(0,64);
		}while(!curObj.hasAnimationState(state));+/
		auto id=current.addObject(obj);
		if(ntt.id !in triggers.objectIds) // e.g. for some reason, the two altars on ferry have the same id
			triggers.associateId(ntt.id,id);
	}
	void placeSpirit(ref Spirit spirit){
		auto position=Vector3f(spirit.x,spirit.y,spirit.z);
		bool onGround=current.isOnGround(position);
		if(onGround)
			position.z=current.getGroundHeight(position);
		current.addObject(Soul!B(1,position,SoulState.normal));
	}
	void placeWidgets(Widgets w){
		auto curObj=SacObject!B.getWIDG(w.tag);
		foreach(pos;w.positions){
			auto position=Vector3f(pos[0],pos[1],0);
			if(!current.isOnGround(position)) continue;
			position.z=current.getGroundHeight(position);
			// original engine screws up widget rotations
			// values look like angles in degrees, but they are actually radians
			auto rotation=facingQuaternion(-pos[2]);
			current.addFixed(FixedObject!B(curObj,position,rotation));
		}
	}

	void step(){
		next.updateFrom(current,commands[current.frame].data);
		swap(current,next);
		if(commands.length<=current.frame) commands~=Array!(Command!B)();
	}
	void commit(){
		lastCommitted.copyFrom(current);
	}
	void rollback(){
		rollback(lastCommitted);
	}
	void rollback(ObjectState!B state)in{
		assert(state.frame<=current.frame);
	}do{
		if(state.frame!=current.frame){
			current.copyFrom(state);
			static if(B.hasAudio) B.updateAudioAfterRollback();
		}
	}
	void rollback(int frame)in{
		assert(frame>=lastCommitted.frame);
	}body{
		if(frame<current.frame) rollback(lastCommitted);
		playAudio=false;
		simulateTo(frame);
	}
	void simulateTo(int frame)in{
		assert(frame>=current.frame);
	}body{
		while(current.frame<frame)
			step();
	}
	void addCommand(int frame,Command!B command)in{
		assert(frame<=current.frame);
	}body{
		assert(frame<commands.length);
		auto currentFrame=current.frame;
		commands[frame]~=command;
		rollback(frame);
		playAudio=false;
		simulateTo(currentFrame);
	}
	void addCommand(Command!B command){
		addCommand(current.frame,command);
	}
	void setSelection(int side,int wizard,CreatureGroup selection,TargetLocation loc){
		addCommand(Command!B(CommandType.clearSelection,side,wizard,0,Target.init,float.init));
		foreach_reverse(id;selection.creatureIds){
			if(id==0) continue;
			addCommand(Command!B(CommandType.automaticToggleSelection,side,wizard,id,Target.init,float.init));
		}
	}
}
