import 'dart:async';
import 'dart:convert';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:provider/provider.dart';
import 'package:frontend/providers/auth_provider.dart';
import 'package:frontend/ui/widgets/realtime_map.dart';
import 'package:frontend/ui/style/color_palette.dart';

class MapScreen extends StatefulWidget {
  const MapScreen({super.key});

  @override
  State<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends State<MapScreen> {
  // Variabile per il throttling del GPS
  Position? _lastCalculatedPosition;

  // Lista filtrata e ordinata da mostrare
  List<Map<String, dynamic>> _nearestPoints = [];

  bool _isLoadingList = true;
  String? _errorList;

  // Streams
  StreamSubscription<Position>? _positionStream;
  StreamSubscription? _databaseSubscription;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _initTracking();
    });
  }

  @override
  void dispose() {
    _positionStream?.cancel();
    _databaseSubscription?.cancel();
    super.dispose();
  }

  Future<void> _initTracking() async {
    final authProvider = Provider.of<AuthProvider>(context, listen: false);

    try {
      _lastCalculatedPosition = null;

      // 1. Controllo Permessi GPS
      bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) {
        await Geolocator.openLocationSettings();
        serviceEnabled = await Geolocator.isLocationServiceEnabled();
        if (!serviceEnabled) throw Exception("GPS disabilitato");
      }

      LocationPermission permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
        if (permission == LocationPermission.denied) {
          throw Exception("Permessi GPS negati");
        }
      }

      if (!mounted) return;

      // 2. Avvio Ascolto Database (REAL-TIME)
      final isRescuer = authProvider.isRescuer;
      if (isRescuer) {
        _startListeningToEmergencies();
      } else {
        _startListeningToSafePoints();
      }

      // 3. Avvio Tracking Posizione GPS
      const locationSettings = LocationSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: 10,
      );

      _positionStream =
          Geolocator.getPositionStream(
            locationSettings: locationSettings,
          ).listen(
            (Position position) {
              // Aggiornamento da GPS: force = false (usa throttling)
              _updateDistances(position, force: false);
            },
            onError: (e) {
              if (mounted) setState(() => _errorList = "Errore GPS: $e");
            },
          );

      // Primo calcolo immediato posizione
      Geolocator.getCurrentPosition()
          .then((pos) => _updateDistances(pos, force: true))
          .catchError((_) {});
    } catch (e) {
      if (mounted) {
        setState(() {
          _errorList = e.toString();
          _isLoadingList = false;
        });
      }
    }
  }

  // --- LOGICA REAL-TIME PER SOCCORRITORI ---
  void _startListeningToEmergencies() {
    _databaseSubscription?.cancel();

    _databaseSubscription = FirebaseFirestore.instance
        .collection('active_emergencies')
        .snapshots()
        .listen(
          (snapshot) {
            List<Map<String, dynamic>> loadedPoints = [];

            for (var doc in snapshot.docs) {
              final data = doc.data();
              final double? lat = (data['lat'] is num)
                  ? (data['lat'] as num).toDouble()
                  : null;
              final double? lng = (data['lng'] is num)
                  ? (data['lng'] as num).toDouble()
                  : null;
              final String type = data['type']?.toString() ?? "Emergenza";
              final String desc =
                  data['description']?.toString() ?? "Nessuna descrizione";

              if (type == 'SAFE') continue;

              if (lat != null && lng != null) {
                loadedPoints.add({
                  'title': type.toUpperCase(),
                  'subtitle': desc,
                  'type': 'emergency',
                  'severity': data['severity'] ?? 1,
                  'lat': lat,
                  'lng': lng,
                  'distance': double.infinity,
                });
              }
            }


            if (_lastCalculatedPosition != null) {
              // Aggiornamento da DB: force = true (ignora throttling e aggiorna subito)
              _updateDistances(_lastCalculatedPosition!, force: true);
            } else {
              if (mounted) setState(() => _isLoadingList = false);
            }
          },
          onError: (e) {
            debugPrint("Errore stream emergenze: $e");
          },
        );
  }

  // --- LOGICA REAL-TIME PER CITTADINI ---
  void _startListeningToSafePoints() {
    _databaseSubscription?.cancel();

    _databaseSubscription = StreamHelper.combineSafePointsAndHospitals().listen(
      (List<Map<String, dynamic>> combinedPoints) {
        if (_lastCalculatedPosition != null) {
          // Aggiornamento da DB: force = true
          _updateDistances(_lastCalculatedPosition!, force: true);
        } else {
          if (mounted) setState(() => _isLoadingList = false);
        }
      },
    );
  }

  // Ricalcolo Distanze e Ordinamento
  Future<void> _updateDistances(Position userPos, {bool force = false}) async {
    // Throttling GPS (10 metri)
    if (!force && _lastCalculatedPosition != null) {
      double movement = Geolocator.distanceBetween(
        userPos.latitude, userPos.longitude,
        _lastCalculatedPosition!.latitude, _lastCalculatedPosition!.longitude,
      );
      if (movement < 10) return;
    }
    _lastCalculatedPosition = userPos;

    // Caricamento solo se necessario
    if (_nearestPoints.isEmpty) setState(() => _isLoadingList = true);

    try {
      // CHIAMATA AL SERVER PYTHON (IA)
      // Se usi emulatore Android usa 10.0.2.2, se fisico usa l'IP del PC
      final response = await http.post(
        Uri.parse('http://10.0.2.2:8000/api/safe-points/sorted'),
        headers: {"Content-Type": "application/json"},
        body: jsonEncode({
          "lat": userPos.latitude,
          "lng": userPos.longitude,
        }),
      ).timeout(const Duration(seconds: 60));

      if (response.statusCode == 200) {
        print("RISPOSTA DA PYTHON: ${response.body}");
        final List<dynamic> data = json.decode(response.body);

        if (mounted) {
          setState(() {
            _nearestPoints = data.map((e) => {
              'title': e['title']?.toString() ?? 'N/A',
              'subtitle': e['isDangerous'] ? "⚠️ PERCORSO OSTRUITO" : (e['subtitle'] ?? "Sicuro"),
              'type': e['type']?.toString() ?? '',
              'lat': (e['lat'] as num).toDouble(),
              'lng': (e['lng'] as num).toDouble(),
              'distance': (e['distance'] as num).toDouble(),
              'isDangerous': e['isDangerous'] ?? false,
            }).toList();

            _nearestPoints.sort((a, b) {
              if (a['isDangerous'] != b['isDangerous']) {
                return a['isDangerous'] ? 1 : -1; // Se a è pericoloso, va dopo (1)
              }
              return (a['distance'] as double).compareTo(b['distance'] as double);
            });

            _isLoadingList = false;
            _errorList = null;
          });
        }
      }
    } catch (e) {
      debugPrint("Errore IA: $e");
      if (mounted) {
        setState(() {
          _errorList = "Server IA offline";
          _isLoadingList = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final isRescuer = context.watch<AuthProvider>().isRescuer;

    final Color panelColor = isRescuer
        ? ColorPalette.primaryOrange
        : ColorPalette.backgroundDarkBlue;
    final Color cardColor = isRescuer
        ? ColorPalette.primaryOrange
        : ColorPalette.backgroundDarkBlue;
    final String listTitle = isRescuer
        ? "Interventi più vicini"
        : "Punti sicuri più vicini";
    final IconData headerIcon = isRescuer
        ? Icons.warning_amber_rounded
        : Icons.directions_walk;

    return Scaffold(
      backgroundColor: ColorPalette.backgroundDarkBlue,
      body: Stack(
        children: [
          Positioned.fill(
            child: RealtimeMap(
              onCenterPressed: () async {
                // Otteniamo la posizione attuale e forziamo il ricalcolo
                Position currentPos = await Geolocator.getCurrentPosition();
                _updateDistances(currentPos, force: true);
              },
            ),
          ),

          DraggableScrollableSheet(
            initialChildSize: 0.4,
            minChildSize: 0.15,
            maxChildSize: 0.8,
            builder: (context, scrollController) {
              return Container(
                decoration: BoxDecoration(
                  color: panelColor,
                  borderRadius: const BorderRadius.vertical(
                    top: Radius.circular(20),
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.3),
                      blurRadius: 10,
                      offset: const Offset(0, -5),
                    ),
                  ],
                ),
                child: ClipRRect(
                  borderRadius: const BorderRadius.vertical(
                    top: Radius.circular(20),
                  ),
                  child: CustomScrollView(
                    controller: scrollController,
                    slivers: [
                      SliverAppBar(
                        pinned: true,
                        floating: false,
                        backgroundColor: panelColor,
                        automaticallyImplyLeading: false,
                        elevation: 0,
                        toolbarHeight: 75,
                        flexibleSpace: Column(
                          mainAxisAlignment: MainAxisAlignment.end,
                          children: [
                            Center(
                              child: Container(
                                margin: const EdgeInsets.only(
                                  top: 10,
                                  bottom: 5,
                                ),
                                width: 40,
                                height: 5,
                                decoration: BoxDecoration(
                                  color: Colors.white24,
                                  borderRadius: BorderRadius.circular(10),
                                ),
                              ),
                            ),
                            Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 20,
                                vertical: 8,
                              ),
                              child: Row(
                                children: [
                                  Icon(headerIcon, color: Colors.white),
                                  const SizedBox(width: 10),
                                  Text(
                                    listTitle,
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 18,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            const Divider(color: Colors.white12, height: 1),
                          ],
                        ),
                      ),
                      if (_isLoadingList)
                        const SliverFillRemaining(
                          hasScrollBody: false,
                          child: Center(
                            child: CircularProgressIndicator(
                              color: Colors.white,
                            ),
                          ),
                        )
                      else if (_errorList != null)
                        SliverFillRemaining(
                          hasScrollBody: false,
                          child: Center(
                            child: Text(
                              "Errore: $_errorList",
                              style: const TextStyle(color: Colors.redAccent),
                            ),
                          ),
                        )
                      else if (_nearestPoints.isEmpty)
                        SliverFillRemaining(
                          hasScrollBody: false,
                          child: Center(
                            child: Text(
                              isRescuer
                                  ? "Nessuna emergenza attiva."
                                  : "Nessun punto sicuro vicino.",
                              style: const TextStyle(color: Colors.white54),
                            ),
                          ),
                        )
                      else
                          SliverList(
                            delegate: SliverChildBuilderDelegate((context, index) {
                              final item = _nearestPoints[index];

                              // --- 1. RECUPERA IL FLAG DI PERICOLO DALL'IA ---
                              final bool isDangerous = item['isDangerous'] ?? false;

                              final double d = item['distance'];
                              final String distStr = d < 1000
                                  ? "${d.toStringAsFixed(0)} m"
                                  : "${(d / 1000).toStringAsFixed(1)} km";

                              IconData itemIcon;
                              Color iconBgColor;
                              Color iconColor;

                              // --- 2. LOGICA ICONE: Se è pericoloso, cambia icona a prescindere dal tipo ---
                              if (isDangerous) {
                                itemIcon = Icons.warning_amber_rounded;
                                iconBgColor = Colors.red.withValues(alpha: 0.2);
                                iconColor = Colors.white;
                              } else if (item['type'] == 'hospital') {
                                itemIcon = Icons.local_hospital;
                                iconBgColor = Colors.blue.withValues(alpha: 0.2);
                                iconColor = Colors.blueAccent;
                              } else {
                                itemIcon = Icons.verified_user;
                                iconBgColor = Colors.green.withValues(alpha: 0.2);
                                iconColor = Colors.greenAccent;
                              }

                              return Card(
                                // --- 3. CAMBIO COLORE CARD: Se pericoloso diventa rosso scuro ---
                                color: isDangerous ? const Color(0xFFB71C1C) : cardColor,
                                elevation: isDangerous ? 0 : 4,
                                margin: const EdgeInsets.symmetric(horizontal: 15, vertical: 5),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(15),
                                  // Aggiungiamo un bordo bianco sottile se è pericoloso per farlo risaltare
                                  side: isDangerous ? const BorderSide(color: Colors.white, width: 1) : BorderSide.none,
                                ),
                                child: ListTile(
                                  contentPadding: const EdgeInsets.symmetric(horizontal: 15, vertical: 5),
                                  leading: CircleAvatar(
                                    backgroundColor: iconBgColor,
                                    child: Icon(itemIcon, color: iconColor),
                                  ),
                                  title: Text(
                                    item['title'],
                                    style: TextStyle(
                                      color: Colors.white,
                                      fontWeight: FontWeight.bold,
                                      // Sbarra il testo se il percorso è bloccato
                                      decoration: isDangerous ? TextDecoration.lineThrough : null,
                                    ),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  subtitle: Text(
                                    // --- 4. CAMBIO SOTTOTITOLO ---
                                    isDangerous ? "⚠️ PERCORSO OSTRUITO (IA)" : item['subtitle'],
                                    style: TextStyle(
                                      color: isDangerous ? Colors.white : Colors.white70,
                                      fontSize: 12,
                                      fontWeight: isDangerous ? FontWeight.bold : FontWeight.normal,
                                    ),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  trailing: Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                                    decoration: BoxDecoration(
                                      color: isDangerous ? Colors.black45 : Colors.black26,
                                      borderRadius: BorderRadius.circular(10),
                                    ),
                                    child: Text(
                                      // Se è pericoloso scriviamo "BLOCCATO" invece della distanza
                                      isDangerous ? "BLOCCATO" : distStr,
                                      style: const TextStyle(
                                        color: Colors.white,
                                        fontWeight: FontWeight.bold,
                                        fontSize: 11,
                                      ),
                                    ),
                                  ),
                                ),
                              );
                            }, childCount: _nearestPoints.length),
                          ),
                      const SliverToBoxAdapter(child: SizedBox(height: 30)),
                    ],
                  ),
                ),
              );
            },
          ),
        ],
      ),
    );
  }
}

// Helper locale per unire due stream
class StreamHelper {
  static Stream<List<Map<String, dynamic>>> combineSafePointsAndHospitals() {
    late StreamController<List<Map<String, dynamic>>> controller;

    List<Map<String, dynamic>> safePoints = [];
    List<Map<String, dynamic>> hospitals = [];

    void emit() {
      controller.add([...safePoints, ...hospitals]);
    }

    controller = StreamController<List<Map<String, dynamic>>>(
      onListen: () {
        FirebaseFirestore.instance.collection('safe_points').snapshots().listen(
          (snap) {
            safePoints = snap.docs.map((doc) {
              final data = doc.data();
              return {
                'title': data['name'] ?? 'Punto Sicuro',
                'subtitle': "Punto di Raccolta",
                'type': 'safe_point',
                'lat': (data['lat'] as num).toDouble(),
                'lng': (data['lng'] as num).toDouble(),
                'distance': double.infinity,
              };
            }).toList();
            emit();
          },
        );

        FirebaseFirestore.instance.collection('hospitals').snapshots().listen((
          snap,
        ) {
          hospitals = snap.docs.map((doc) {
            final data = doc.data();
            return {
              'title': data['name'] ?? 'Ospedale',
              'subtitle': "Pronto Soccorso",
              'type': 'hospital',
              'lat': (data['lat'] as num).toDouble(),
              'lng': (data['lng'] as num).toDouble(),
              'distance': double.infinity,
            };
          }).toList();
          emit();
        });
      },
    );

    return controller.stream;
  }
}
