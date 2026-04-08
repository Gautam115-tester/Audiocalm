// lib/core/di/providers.dart

import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../network/dio_client.dart';

final dioClientProvider = Provider<DioClient>((ref) {
  return DioClient();
});
