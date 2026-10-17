// GENERATED CODE - DO NOT MODIFY BY HAND
// coverage:ignore-file
// ignore_for_file: type=lint
// ignore_for_file: unused_element, deprecated_member_use, deprecated_member_use_from_same_package, use_function_type_syntax_for_parameters, unnecessary_const, avoid_init_to_null, invalid_override_different_default_values_named, prefer_expression_function_bodies, annotate_overrides, invalid_annotation_target, unnecessary_question_mark

part of 'screen.dart';

// **************************************************************************
// FreezedGenerator
// **************************************************************************

// dart format off
T _$identity<T>(T value) => value;
/// @nodoc
mixin _$RsScreenEvent {





@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is RsScreenEvent);
}


@override
int get hashCode => runtimeType.hashCode;

@override
String toString() {
  return 'RsScreenEvent()';
}


}

/// @nodoc
class $RsScreenEventCopyWith<$Res>  {
$RsScreenEventCopyWith(RsScreenEvent _, $Res Function(RsScreenEvent) __);
}


/// Adds pattern-matching-related methods to [RsScreenEvent].
extension RsScreenEventPatterns on RsScreenEvent {
/// A variant of `map` that fallback to returning `orElse`.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case _:
///     return orElse();
/// }
/// ```

@optionalTypeArgs TResult maybeMap<TResult extends Object?>({TResult Function( RsScreenEvent_Status value)?  status,TResult Function( RsScreenEvent_Stats value)?  stats,TResult Function( RsScreenEvent_Ended value)?  ended,TResult Function( RsScreenEvent_Error value)?  error,required TResult orElse(),}){
final _that = this;
switch (_that) {
case RsScreenEvent_Status() when status != null:
return status(_that);case RsScreenEvent_Stats() when stats != null:
return stats(_that);case RsScreenEvent_Ended() when ended != null:
return ended(_that);case RsScreenEvent_Error() when error != null:
return error(_that);case _:
  return orElse();

}
}
/// A `switch`-like method, using callbacks.
///
/// Callbacks receives the raw object, upcasted.
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case final Subclass2 value:
///     return ...;
/// }
/// ```

@optionalTypeArgs TResult map<TResult extends Object?>({required TResult Function( RsScreenEvent_Status value)  status,required TResult Function( RsScreenEvent_Stats value)  stats,required TResult Function( RsScreenEvent_Ended value)  ended,required TResult Function( RsScreenEvent_Error value)  error,}){
final _that = this;
switch (_that) {
case RsScreenEvent_Status():
return status(_that);case RsScreenEvent_Stats():
return stats(_that);case RsScreenEvent_Ended():
return ended(_that);case RsScreenEvent_Error():
return error(_that);}
}
/// A variant of `map` that fallback to returning `null`.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case _:
///     return null;
/// }
/// ```

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>({TResult? Function( RsScreenEvent_Status value)?  status,TResult? Function( RsScreenEvent_Stats value)?  stats,TResult? Function( RsScreenEvent_Ended value)?  ended,TResult? Function( RsScreenEvent_Error value)?  error,}){
final _that = this;
switch (_that) {
case RsScreenEvent_Status() when status != null:
return status(_that);case RsScreenEvent_Stats() when stats != null:
return stats(_that);case RsScreenEvent_Ended() when ended != null:
return ended(_that);case RsScreenEvent_Error() when error != null:
return error(_that);case _:
  return null;

}
}
/// A variant of `when` that fallback to an `orElse` callback.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case _:
///     return orElse();
/// }
/// ```

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>({TResult Function( String state)?  status,TResult Function( BigInt frames,  BigInt keyframes,  double fps,  double mbps,  BigInt packets,  BigInt lost,  BigInt decodeErrors)?  stats,TResult Function( String reason)?  ended,TResult Function( String message)?  error,required TResult orElse(),}) {final _that = this;
switch (_that) {
case RsScreenEvent_Status() when status != null:
return status(_that.state);case RsScreenEvent_Stats() when stats != null:
return stats(_that.frames,_that.keyframes,_that.fps,_that.mbps,_that.packets,_that.lost,_that.decodeErrors);case RsScreenEvent_Ended() when ended != null:
return ended(_that.reason);case RsScreenEvent_Error() when error != null:
return error(_that.message);case _:
  return orElse();

}
}
/// A `switch`-like method, using callbacks.
///
/// As opposed to `map`, this offers destructuring.
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case Subclass2(:final field2):
///     return ...;
/// }
/// ```

@optionalTypeArgs TResult when<TResult extends Object?>({required TResult Function( String state)  status,required TResult Function( BigInt frames,  BigInt keyframes,  double fps,  double mbps,  BigInt packets,  BigInt lost,  BigInt decodeErrors)  stats,required TResult Function( String reason)  ended,required TResult Function( String message)  error,}) {final _that = this;
switch (_that) {
case RsScreenEvent_Status():
return status(_that.state);case RsScreenEvent_Stats():
return stats(_that.frames,_that.keyframes,_that.fps,_that.mbps,_that.packets,_that.lost,_that.decodeErrors);case RsScreenEvent_Ended():
return ended(_that.reason);case RsScreenEvent_Error():
return error(_that.message);}
}
/// A variant of `when` that fallback to returning `null`
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case _:
///     return null;
/// }
/// ```

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>({TResult? Function( String state)?  status,TResult? Function( BigInt frames,  BigInt keyframes,  double fps,  double mbps,  BigInt packets,  BigInt lost,  BigInt decodeErrors)?  stats,TResult? Function( String reason)?  ended,TResult? Function( String message)?  error,}) {final _that = this;
switch (_that) {
case RsScreenEvent_Status() when status != null:
return status(_that.state);case RsScreenEvent_Stats() when stats != null:
return stats(_that.frames,_that.keyframes,_that.fps,_that.mbps,_that.packets,_that.lost,_that.decodeErrors);case RsScreenEvent_Ended() when ended != null:
return ended(_that.reason);case RsScreenEvent_Error() when error != null:
return error(_that.message);case _:
  return null;

}
}

}

/// @nodoc


class RsScreenEvent_Status extends RsScreenEvent {
  const RsScreenEvent_Status({required this.state}): super._();
  

 final  String state;

/// Create a copy of RsScreenEvent
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$RsScreenEvent_StatusCopyWith<RsScreenEvent_Status> get copyWith => _$RsScreenEvent_StatusCopyWithImpl<RsScreenEvent_Status>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is RsScreenEvent_Status&&(identical(other.state, state) || other.state == state));
}


@override
int get hashCode => Object.hash(runtimeType,state);

@override
String toString() {
  return 'RsScreenEvent.status(state: $state)';
}


}

/// @nodoc
abstract mixin class $RsScreenEvent_StatusCopyWith<$Res> implements $RsScreenEventCopyWith<$Res> {
  factory $RsScreenEvent_StatusCopyWith(RsScreenEvent_Status value, $Res Function(RsScreenEvent_Status) _then) = _$RsScreenEvent_StatusCopyWithImpl;
@useResult
$Res call({
 String state
});




}
/// @nodoc
class _$RsScreenEvent_StatusCopyWithImpl<$Res>
    implements $RsScreenEvent_StatusCopyWith<$Res> {
  _$RsScreenEvent_StatusCopyWithImpl(this._self, this._then);

  final RsScreenEvent_Status _self;
  final $Res Function(RsScreenEvent_Status) _then;

/// Create a copy of RsScreenEvent
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? state = null,}) {
  return _then(RsScreenEvent_Status(
state: null == state ? _self.state : state // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}

/// @nodoc


class RsScreenEvent_Stats extends RsScreenEvent {
  const RsScreenEvent_Stats({required this.frames, required this.keyframes, required this.fps, required this.mbps, required this.packets, required this.lost, required this.decodeErrors}): super._();
  

 final  BigInt frames;
 final  BigInt keyframes;
 final  double fps;
 final  double mbps;
 final  BigInt packets;
 final  BigInt lost;
 final  BigInt decodeErrors;

/// Create a copy of RsScreenEvent
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$RsScreenEvent_StatsCopyWith<RsScreenEvent_Stats> get copyWith => _$RsScreenEvent_StatsCopyWithImpl<RsScreenEvent_Stats>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is RsScreenEvent_Stats&&(identical(other.frames, frames) || other.frames == frames)&&(identical(other.keyframes, keyframes) || other.keyframes == keyframes)&&(identical(other.fps, fps) || other.fps == fps)&&(identical(other.mbps, mbps) || other.mbps == mbps)&&(identical(other.packets, packets) || other.packets == packets)&&(identical(other.lost, lost) || other.lost == lost)&&(identical(other.decodeErrors, decodeErrors) || other.decodeErrors == decodeErrors));
}


@override
int get hashCode => Object.hash(runtimeType,frames,keyframes,fps,mbps,packets,lost,decodeErrors);

@override
String toString() {
  return 'RsScreenEvent.stats(frames: $frames, keyframes: $keyframes, fps: $fps, mbps: $mbps, packets: $packets, lost: $lost, decodeErrors: $decodeErrors)';
}


}

/// @nodoc
abstract mixin class $RsScreenEvent_StatsCopyWith<$Res> implements $RsScreenEventCopyWith<$Res> {
  factory $RsScreenEvent_StatsCopyWith(RsScreenEvent_Stats value, $Res Function(RsScreenEvent_Stats) _then) = _$RsScreenEvent_StatsCopyWithImpl;
@useResult
$Res call({
 BigInt frames, BigInt keyframes, double fps, double mbps, BigInt packets, BigInt lost, BigInt decodeErrors
});




}
/// @nodoc
class _$RsScreenEvent_StatsCopyWithImpl<$Res>
    implements $RsScreenEvent_StatsCopyWith<$Res> {
  _$RsScreenEvent_StatsCopyWithImpl(this._self, this._then);

  final RsScreenEvent_Stats _self;
  final $Res Function(RsScreenEvent_Stats) _then;

/// Create a copy of RsScreenEvent
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? frames = null,Object? keyframes = null,Object? fps = null,Object? mbps = null,Object? packets = null,Object? lost = null,Object? decodeErrors = null,}) {
  return _then(RsScreenEvent_Stats(
frames: null == frames ? _self.frames : frames // ignore: cast_nullable_to_non_nullable
as BigInt,keyframes: null == keyframes ? _self.keyframes : keyframes // ignore: cast_nullable_to_non_nullable
as BigInt,fps: null == fps ? _self.fps : fps // ignore: cast_nullable_to_non_nullable
as double,mbps: null == mbps ? _self.mbps : mbps // ignore: cast_nullable_to_non_nullable
as double,packets: null == packets ? _self.packets : packets // ignore: cast_nullable_to_non_nullable
as BigInt,lost: null == lost ? _self.lost : lost // ignore: cast_nullable_to_non_nullable
as BigInt,decodeErrors: null == decodeErrors ? _self.decodeErrors : decodeErrors // ignore: cast_nullable_to_non_nullable
as BigInt,
  ));
}


}

/// @nodoc


class RsScreenEvent_Ended extends RsScreenEvent {
  const RsScreenEvent_Ended({required this.reason}): super._();
  

 final  String reason;

/// Create a copy of RsScreenEvent
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$RsScreenEvent_EndedCopyWith<RsScreenEvent_Ended> get copyWith => _$RsScreenEvent_EndedCopyWithImpl<RsScreenEvent_Ended>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is RsScreenEvent_Ended&&(identical(other.reason, reason) || other.reason == reason));
}


@override
int get hashCode => Object.hash(runtimeType,reason);

@override
String toString() {
  return 'RsScreenEvent.ended(reason: $reason)';
}


}

/// @nodoc
abstract mixin class $RsScreenEvent_EndedCopyWith<$Res> implements $RsScreenEventCopyWith<$Res> {
  factory $RsScreenEvent_EndedCopyWith(RsScreenEvent_Ended value, $Res Function(RsScreenEvent_Ended) _then) = _$RsScreenEvent_EndedCopyWithImpl;
@useResult
$Res call({
 String reason
});




}
/// @nodoc
class _$RsScreenEvent_EndedCopyWithImpl<$Res>
    implements $RsScreenEvent_EndedCopyWith<$Res> {
  _$RsScreenEvent_EndedCopyWithImpl(this._self, this._then);

  final RsScreenEvent_Ended _self;
  final $Res Function(RsScreenEvent_Ended) _then;

/// Create a copy of RsScreenEvent
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? reason = null,}) {
  return _then(RsScreenEvent_Ended(
reason: null == reason ? _self.reason : reason // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}

/// @nodoc


class RsScreenEvent_Error extends RsScreenEvent {
  const RsScreenEvent_Error({required this.message}): super._();
  

 final  String message;

/// Create a copy of RsScreenEvent
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$RsScreenEvent_ErrorCopyWith<RsScreenEvent_Error> get copyWith => _$RsScreenEvent_ErrorCopyWithImpl<RsScreenEvent_Error>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is RsScreenEvent_Error&&(identical(other.message, message) || other.message == message));
}


@override
int get hashCode => Object.hash(runtimeType,message);

@override
String toString() {
  return 'RsScreenEvent.error(message: $message)';
}


}

/// @nodoc
abstract mixin class $RsScreenEvent_ErrorCopyWith<$Res> implements $RsScreenEventCopyWith<$Res> {
  factory $RsScreenEvent_ErrorCopyWith(RsScreenEvent_Error value, $Res Function(RsScreenEvent_Error) _then) = _$RsScreenEvent_ErrorCopyWithImpl;
@useResult
$Res call({
 String message
});




}
/// @nodoc
class _$RsScreenEvent_ErrorCopyWithImpl<$Res>
    implements $RsScreenEvent_ErrorCopyWith<$Res> {
  _$RsScreenEvent_ErrorCopyWithImpl(this._self, this._then);

  final RsScreenEvent_Error _self;
  final $Res Function(RsScreenEvent_Error) _then;

/// Create a copy of RsScreenEvent
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? message = null,}) {
  return _then(RsScreenEvent_Error(
message: null == message ? _self.message : message // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}

// dart format on
