// lib/features/downloads/data/models/download_model.g.dart
// GENERATED CODE - Hand-written adapter to avoid build_runner dependency issues

part of 'download_model.dart';

class DownloadModelAdapter extends TypeAdapter<DownloadModel> {
  @override
  final int typeId = 0;

  @override
  DownloadModel read(BinaryReader reader) {
    final numOfFields = reader.readByte();
    final fields = <int, dynamic>{
      for (int i = 0; i < numOfFields; i++) reader.readByte(): reader.read(),
    };
    return DownloadModel(
      id: fields[0] as String,
      mediaId: fields[1] as String,
      title: fields[2] as String,
      artworkUrl: fields[3] as String?,
      mediaType: fields[4] as String,
      encryptedFilePath: fields[5] as String,
      totalParts: fields[6] as int,
      downloadedParts: fields[7] as int,
      status: fields[8] as String,
      progress: fields[9] as double,
      createdAt: fields[10] as DateTime,
      errorMessage: fields[11] as String?,
      subtitle: fields[12] as String?,
      fileSizeBytes: fields[13] as int,
    );
  }

  @override
  void write(BinaryWriter writer, DownloadModel obj) {
    writer
      ..writeByte(14)
      ..writeByte(0)
      ..write(obj.id)
      ..writeByte(1)
      ..write(obj.mediaId)
      ..writeByte(2)
      ..write(obj.title)
      ..writeByte(3)
      ..write(obj.artworkUrl)
      ..writeByte(4)
      ..write(obj.mediaType)
      ..writeByte(5)
      ..write(obj.encryptedFilePath)
      ..writeByte(6)
      ..write(obj.totalParts)
      ..writeByte(7)
      ..write(obj.downloadedParts)
      ..writeByte(8)
      ..write(obj.status)
      ..writeByte(9)
      ..write(obj.progress)
      ..writeByte(10)
      ..write(obj.createdAt)
      ..writeByte(11)
      ..write(obj.errorMessage)
      ..writeByte(12)
      ..write(obj.subtitle)
      ..writeByte(13)
      ..write(obj.fileSizeBytes);
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DownloadModelAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}
