// copyright © tg
// distributed under the terms of the gplv3 license
// https://www.gnu.org/licenses/gpl-3.0.txt

struct Animations{
	union{
		char[4][64] animations;
		struct{
			char[4] stance1;
			char[4][4] idle;
			char[4] tumble;
			char[4] run;
			char[4] falling; // for dying creatures that are in the air and when falling with exclusively vertical velocity component
			char[4] hitFloor;
			char[4] knocked2Floor; // only for walking creatures
			char[4] getUp;         // only for walking creatures
			char[4][3] attack;
			char[4] damageFront;
			char[4] damageRight;
			char[4] damageBack;
			char[4] damageLeft;
			char[4] damageTop;
			char[4][3] death;
			char[4][2] shoot;
			char[4] walk; // only different from run for Eldred
			char[4] thrash;
			char[4] spellcastStart; // wizards only
			char[4] spellcast; // wizards only
			char[4] spellcastEnd; // wizards only
			char[4] runSpellcastStart; // wizards only
			char[4] runSpellcast; // wizards only
			char[4] runSpellcastEnd; // wizards only
			char[4] takeoff; // peasants: cower
			char[4] fly; // peasants: pull
			char[4] land; // peasants: pull 2
			char[4] flyDamage; // peasants: dig
			char[4] flyDeath;  // peasants: pull down
			char[4] flyAttack; // peasants: talk/cower
			char[4] hover;
			char[4] pickUp;
			char[4] badLanding;
			char[4] carry;
			char[4] carried; // special for hellmouth
			char[4] flyShoot;
			char[4] notify;
			char[4] stance2; // stance when damaged
			char[4] rise;
			char[4] corpse;
			char[4] float_;
			char[4] float2Thrash;
			char[4] sorrow;
			char[4] doubletake;
			char[4] ambivalence;
			char[4] disgust;
			char[4] bow;
			char[4] laugh;
			char[4] disoriented;
			char[4] corpseRise;
			char[4] floatStatic; // wizards only
			char[4] floatMove; // wizards only
			char[4] float2Stance; // wizards only
			char[4] talk;
			char[4][2] pulling; // peasants only
		}
	}
}

string generateAnimationState(){
	string[] names;
	import std.conv: to;
	import std.string: join;
	foreach(x;__traits(allMembers,Animations)){
		static if(x!="animations"){
			enum size=__traits(getMember,Animations,x).sizeof;
			static if(size>4){
				static assert(size%4==0);
				foreach(i;0..size/4) names~=x~to!string(i);
			}else names~=x;
		}
	}
	return "enum AnimationState{"~names.join(",")~",pullDown,dig,cower,talkCower}";
}
mixin(generateAnimationState);

enum SacDoctorAnimationState: AnimationState{
	stance=AnimationState.stance1,
	dance=AnimationState.idle0,
	walk=AnimationState.tumble,
	run=AnimationState.run,
	expelled=AnimationState.falling,
	bounce=AnimationState.hitFloor,
	stab=AnimationState.attack0,
	pumpCorpse=AnimationState.attack1,
	pickUpCorpse=AnimationState.attack2,
	stance2Torture=AnimationState.spellcastStart,
	torture=AnimationState.spellcast,
	torture2Stance=AnimationState.spellcastEnd,
}
