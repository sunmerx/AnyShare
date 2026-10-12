// coverage:ignore-file
// GENERATED CODE - DO NOT MODIFY BY HAND
// dart format off
// ignore_for_file: type=lint
// ignore_for_file: invalid_use_of_protected_member
// ignore_for_file: unused_element, unnecessary_cast, override_on_non_overriding_member
// ignore_for_file: strict_raw_type, inference_failure_on_untyped_parameter

part of 'favorite_device.dart';

class TrustLevelMapper extends EnumMapper<TrustLevel> {
  TrustLevelMapper._();

  static TrustLevelMapper? _instance;
  static TrustLevelMapper ensureInitialized() {
    if (_instance == null) {
      MapperContainer.globals.use(_instance = TrustLevelMapper._());
    }
    return _instance!;
  }

  static TrustLevel fromValue(dynamic value) {
    ensureInitialized();
    return MapperContainer.globals.fromValue(value);
  }

  @override
  TrustLevel decode(dynamic value) {
    switch (value) {
      case r'temp':
        return TrustLevel.temp;
      case r'limited':
        return TrustLevel.limited;
      case r'full':
        return TrustLevel.full;
      default:
        throw MapperException.unknownEnumValue(value);
    }
  }

  @override
  dynamic encode(TrustLevel self) {
    switch (self) {
      case TrustLevel.temp:
        return r'temp';
      case TrustLevel.limited:
        return r'limited';
      case TrustLevel.full:
        return r'full';
    }
  }
}

extension TrustLevelMapperExtension on TrustLevel {
  String toValue() {
    TrustLevelMapper.ensureInitialized();
    return MapperContainer.globals.toValue<TrustLevel>(this) as String;
  }
}

class QuotaModeMapper extends EnumMapper<QuotaMode> {
  QuotaModeMapper._();

  static QuotaModeMapper? _instance;
  static QuotaModeMapper ensureInitialized() {
    if (_instance == null) {
      MapperContainer.globals.use(_instance = QuotaModeMapper._());
    }
    return _instance!;
  }

  static QuotaMode fromValue(dynamic value) {
    ensureInitialized();
    return MapperContainer.globals.fromValue(value);
  }

  @override
  QuotaMode decode(dynamic value) {
    switch (value) {
      case r'none':
        return QuotaMode.none;
      case r'absolute':
        return QuotaMode.absolute;
      case r'percent':
        return QuotaMode.percent;
      default:
        throw MapperException.unknownEnumValue(value);
    }
  }

  @override
  dynamic encode(QuotaMode self) {
    switch (self) {
      case QuotaMode.none:
        return r'none';
      case QuotaMode.absolute:
        return r'absolute';
      case QuotaMode.percent:
        return r'percent';
    }
  }
}

extension QuotaModeMapperExtension on QuotaMode {
  String toValue() {
    QuotaModeMapper.ensureInitialized();
    return MapperContainer.globals.toValue<QuotaMode>(this) as String;
  }
}

class FavoriteDeviceMapper extends ClassMapperBase<FavoriteDevice> {
  FavoriteDeviceMapper._();

  static FavoriteDeviceMapper? _instance;
  static FavoriteDeviceMapper ensureInitialized() {
    if (_instance == null) {
      MapperContainer.globals.use(_instance = FavoriteDeviceMapper._());
      TrustLevelMapper.ensureInitialized();
      QuotaModeMapper.ensureInitialized();
    }
    return _instance!;
  }

  @override
  final String id = 'FavoriteDevice';

  static String _$id(FavoriteDevice v) => v.id;
  static const Field<FavoriteDevice, String> _f$id = Field('id', _$id);
  static String _$fingerprint(FavoriteDevice v) => v.fingerprint;
  static const Field<FavoriteDevice, String> _f$fingerprint = Field(
    'fingerprint',
    _$fingerprint,
  );
  static String _$ip(FavoriteDevice v) => v.ip;
  static const Field<FavoriteDevice, String> _f$ip = Field('ip', _$ip);
  static int _$port(FavoriteDevice v) => v.port;
  static const Field<FavoriteDevice, int> _f$port = Field('port', _$port);
  static String _$alias(FavoriteDevice v) => v.alias;
  static const Field<FavoriteDevice, String> _f$alias = Field('alias', _$alias);
  static bool _$customAlias(FavoriteDevice v) => v.customAlias;
  static const Field<FavoriteDevice, bool> _f$customAlias = Field(
    'customAlias',
    _$customAlias,
    opt: true,
    def: false,
  );
  static String _$ownerId(FavoriteDevice v) => v.ownerId;
  static const Field<FavoriteDevice, String> _f$ownerId = Field(
    'ownerId',
    _$ownerId,
    opt: true,
    def: '',
  );
  static String _$ownerName(FavoriteDevice v) => v.ownerName;
  static const Field<FavoriteDevice, String> _f$ownerName = Field(
    'ownerName',
    _$ownerName,
    opt: true,
    def: '',
  );
  static TrustLevel _$trustLevel(FavoriteDevice v) => v.trustLevel;
  static const Field<FavoriteDevice, TrustLevel> _f$trustLevel = Field(
    'trustLevel',
    _$trustLevel,
    opt: true,
    def: TrustLevel.full,
  );
  static bool _$blocked(FavoriteDevice v) => v.blocked;
  static const Field<FavoriteDevice, bool> _f$blocked = Field(
    'blocked',
    _$blocked,
    opt: true,
    def: false,
  );
  static int _$maxFileSize(FavoriteDevice v) => v.maxFileSize;
  static const Field<FavoriteDevice, int> _f$maxFileSize = Field(
    'maxFileSize',
    _$maxFileSize,
    opt: true,
    def: 0,
  );
  static QuotaMode _$quotaMode(FavoriteDevice v) => v.quotaMode;
  static const Field<FavoriteDevice, QuotaMode> _f$quotaMode = Field(
    'quotaMode',
    _$quotaMode,
    opt: true,
    def: QuotaMode.none,
  );
  static int _$quotaValue(FavoriteDevice v) => v.quotaValue;
  static const Field<FavoriteDevice, int> _f$quotaValue = Field(
    'quotaValue',
    _$quotaValue,
    opt: true,
    def: 0,
  );

  @override
  final MappableFields<FavoriteDevice> fields = const {
    #id: _f$id,
    #fingerprint: _f$fingerprint,
    #ip: _f$ip,
    #port: _f$port,
    #alias: _f$alias,
    #customAlias: _f$customAlias,
    #ownerId: _f$ownerId,
    #ownerName: _f$ownerName,
    #trustLevel: _f$trustLevel,
    #blocked: _f$blocked,
    #maxFileSize: _f$maxFileSize,
    #quotaMode: _f$quotaMode,
    #quotaValue: _f$quotaValue,
  };

  static FavoriteDevice _instantiate(DecodingData data) {
    return FavoriteDevice(
      id: data.dec(_f$id),
      fingerprint: data.dec(_f$fingerprint),
      ip: data.dec(_f$ip),
      port: data.dec(_f$port),
      alias: data.dec(_f$alias),
      customAlias: data.dec(_f$customAlias),
      ownerId: data.dec(_f$ownerId),
      ownerName: data.dec(_f$ownerName),
      trustLevel: data.dec(_f$trustLevel),
      blocked: data.dec(_f$blocked),
      maxFileSize: data.dec(_f$maxFileSize),
      quotaMode: data.dec(_f$quotaMode),
      quotaValue: data.dec(_f$quotaValue),
    );
  }

  @override
  final Function instantiate = _instantiate;

  static FavoriteDevice fromJson(Map<String, dynamic> map) {
    return ensureInitialized().decodeMap<FavoriteDevice>(map);
  }

  static FavoriteDevice deserialize(String json) {
    return ensureInitialized().decodeJson<FavoriteDevice>(json);
  }
}

mixin FavoriteDeviceMappable {
  String serialize() {
    return FavoriteDeviceMapper.ensureInitialized().encodeJson<FavoriteDevice>(
      this as FavoriteDevice,
    );
  }

  Map<String, dynamic> toJson() {
    return FavoriteDeviceMapper.ensureInitialized().encodeMap<FavoriteDevice>(
      this as FavoriteDevice,
    );
  }

  FavoriteDeviceCopyWith<FavoriteDevice, FavoriteDevice, FavoriteDevice>
  get copyWith => _FavoriteDeviceCopyWithImpl<FavoriteDevice, FavoriteDevice>(
    this as FavoriteDevice,
    $identity,
    $identity,
  );
  @override
  String toString() {
    return FavoriteDeviceMapper.ensureInitialized().stringifyValue(
      this as FavoriteDevice,
    );
  }

  @override
  bool operator ==(Object other) {
    return FavoriteDeviceMapper.ensureInitialized().equalsValue(
      this as FavoriteDevice,
      other,
    );
  }

  @override
  int get hashCode {
    return FavoriteDeviceMapper.ensureInitialized().hashValue(
      this as FavoriteDevice,
    );
  }
}

extension FavoriteDeviceValueCopy<$R, $Out>
    on ObjectCopyWith<$R, FavoriteDevice, $Out> {
  FavoriteDeviceCopyWith<$R, FavoriteDevice, $Out> get $asFavoriteDevice =>
      $base.as((v, t, t2) => _FavoriteDeviceCopyWithImpl<$R, $Out>(v, t, t2));
}

abstract class FavoriteDeviceCopyWith<$R, $In extends FavoriteDevice, $Out>
    implements ClassCopyWith<$R, $In, $Out> {
  $R call({
    String? id,
    String? fingerprint,
    String? ip,
    int? port,
    String? alias,
    bool? customAlias,
    String? ownerId,
    String? ownerName,
    TrustLevel? trustLevel,
    bool? blocked,
    int? maxFileSize,
    QuotaMode? quotaMode,
    int? quotaValue,
  });
  FavoriteDeviceCopyWith<$R2, $In, $Out2> $chain<$R2, $Out2>(
    Then<$Out2, $R2> t,
  );
}

class _FavoriteDeviceCopyWithImpl<$R, $Out>
    extends ClassCopyWithBase<$R, FavoriteDevice, $Out>
    implements FavoriteDeviceCopyWith<$R, FavoriteDevice, $Out> {
  _FavoriteDeviceCopyWithImpl(super.value, super.then, super.then2);

  @override
  late final ClassMapperBase<FavoriteDevice> $mapper =
      FavoriteDeviceMapper.ensureInitialized();
  @override
  $R call({
    String? id,
    String? fingerprint,
    String? ip,
    int? port,
    String? alias,
    bool? customAlias,
    String? ownerId,
    String? ownerName,
    TrustLevel? trustLevel,
    bool? blocked,
    int? maxFileSize,
    QuotaMode? quotaMode,
    int? quotaValue,
  }) => $apply(
    FieldCopyWithData({
      if (id != null) #id: id,
      if (fingerprint != null) #fingerprint: fingerprint,
      if (ip != null) #ip: ip,
      if (port != null) #port: port,
      if (alias != null) #alias: alias,
      if (customAlias != null) #customAlias: customAlias,
      if (ownerId != null) #ownerId: ownerId,
      if (ownerName != null) #ownerName: ownerName,
      if (trustLevel != null) #trustLevel: trustLevel,
      if (blocked != null) #blocked: blocked,
      if (maxFileSize != null) #maxFileSize: maxFileSize,
      if (quotaMode != null) #quotaMode: quotaMode,
      if (quotaValue != null) #quotaValue: quotaValue,
    }),
  );
  @override
  FavoriteDevice $make(CopyWithData data) => FavoriteDevice(
    id: data.get(#id, or: $value.id),
    fingerprint: data.get(#fingerprint, or: $value.fingerprint),
    ip: data.get(#ip, or: $value.ip),
    port: data.get(#port, or: $value.port),
    alias: data.get(#alias, or: $value.alias),
    customAlias: data.get(#customAlias, or: $value.customAlias),
    ownerId: data.get(#ownerId, or: $value.ownerId),
    ownerName: data.get(#ownerName, or: $value.ownerName),
    trustLevel: data.get(#trustLevel, or: $value.trustLevel),
    blocked: data.get(#blocked, or: $value.blocked),
    maxFileSize: data.get(#maxFileSize, or: $value.maxFileSize),
    quotaMode: data.get(#quotaMode, or: $value.quotaMode),
    quotaValue: data.get(#quotaValue, or: $value.quotaValue),
  );

  @override
  FavoriteDeviceCopyWith<$R2, FavoriteDevice, $Out2> $chain<$R2, $Out2>(
    Then<$Out2, $R2> t,
  ) => _FavoriteDeviceCopyWithImpl<$R2, $Out2>($value, $cast, t);
}

