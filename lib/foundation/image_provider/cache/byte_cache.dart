import 'dart:typed_data';

class ByteCache {
  final _data = <String, Uint8List>{};
  final _order = <String>[];
  int maxEntries;

  ByteCache({this.maxEntries = 10});

  Uint8List? get(String key) => _data[key];
  bool contains(String key) => _data.containsKey(key);

  void put(String key, Uint8List data) {
    if (!_data.containsKey(key)) _order.add(key);
    _data[key] = data;
    while (_order.length > maxEntries) {
      _data.remove(_order.removeAt(0));
    }
  }

  void evict(String key) {
    _data.remove(key);
    _order.remove(key);
  }

  void clear() {
    _data.clear();
    _order.clear();
  }
}