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
  List<List<double>>? _selectedPolyline;

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

  // Logica real-time per i soccorritori
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

  // Logica real-time per i cittadini
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
      // Chiamata al server python (IA)
      final response = await http.post(
        Uri.parse('http://10.0.2.2:8000/api/safe-points/sorted'),
        headers: {"Content-Type": "application/json"},
        body: jsonEncode({
          "lat": userPos.latitude,
          "lng": userPos.longitude,
        }),
      ).timeout(const Duration(seconds: 60));

      if (response.statusCode == 200) {
        final List<dynamic> data = json.decode(response.body);

        if (mounted) {
          // Aggiorna lo stato dell'interfaccia utente
          setState(() {
            // Converte la lista di dati dinamici ricevuti dal server (JSON) in una lista mappata
            _nearestPoints = data.map((e) {

              // Recupera i valori con dei default sicuri per evitare i crash
              final double dEffettiva = (e['distance'] ?? 0.0) as double;
              final double dReale = (e['dist_real'] ?? dEffettiva) as double;
              final bool pericoloso = e['isDangerous'] ?? false;
              final bool bloccato = e['isBlocked'] ?? false;

              // Restituisce una mappa strutturata per ogni punto, pronta per essere usata nei Widget
              return {
                'title': e['title']?.toString() ?? 'Punto Ignoto',
                'lat': (e['lat'] ?? 0.0).toDouble(),
                'lng': (e['lng'] ?? 0.0).toDouble(),
                'distance': dEffettiva,
                'dist_real': dReale,
                'isDangerous': pericoloso,
                'isBlocked': bloccato,
                'type': e['type']?.toString() ?? 'generic',
                'polyline': e['polyline'],

                // Logica sottotitolo
                'subtitle': bloccato
                    ? "⚠️ DESTINAZIONE INACCESSIBILE"
                    : (pericoloso
                    ? "⚠️ DEVIAZIONE: +${(dEffettiva - dReale).toStringAsFixed(0)}m"
                    : "Percorso sicuro"),
              };
            }).toList();

            _isLoadingList = false;
          });
        }
      }
    } catch (e) {
      // Gestione degli errori di rete o crash del server Python
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
              selectedPolyline: _selectedPolyline,
              isSelectionMode: false,
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
                              // Recupera l'elemento corrente dalla lista dei punti più vicini
                              final item = _nearestPoints[index];

                              // Verifica se il percorso è deviato (dangerous) o totalmente ostruito (blocked)
                              final bool isDangerous = item['isDangerous'] ?? false;
                              final bool isBlocked = item['isBlocked'] ?? false;

                              // Gestione distanza
                              final double d = item['distance'];
                              String distStr;
                              if (isBlocked) {
                                // Se la destinazione è inaccessibile, non mostra i km
                                distStr = "BLOCCATO";
                              } else {
                                distStr = d < 1000
                                    ? "${d.toStringAsFixed(0)} m"
                                    : "${(d / 1000).toStringAsFixed(1)} km";
                              }

                              IconData itemIcon;
                              Color iconBgColor;
                              Color iconColor;

                              // Logica Icone
                              if (isBlocked) {
                                // Icona per il blocco totale
                                itemIcon = Icons.block;
                                iconBgColor = Colors.black.withValues(alpha: 0.4);
                                iconColor = Colors.redAccent;
                              } else if (isDangerous) {
                                // Icona per i percorsi con deviazione
                                itemIcon = Icons.warning_amber_rounded;
                                iconBgColor = Colors.red.withValues(alpha: 0.2);
                                iconColor = Colors.white;
                              } else if (item['type'] == 'hospital') {
                                // Icona per ospedali
                                itemIcon = Icons.local_hospital;
                                iconBgColor = Colors.blue.withValues(alpha: 0.2);
                                iconColor = Colors.blueAccent;
                              } else {
                                // Icona per punti sicuri
                                itemIcon = Icons.verified_user;
                                iconBgColor = Colors.green.withValues(alpha: 0.2);
                                iconColor = Colors.greenAccent;
                              }

                              return Card(
                                // Colore: Nero se bloccato, Rosso se pericoloso, Blu/Arancio standard altrimenti
                                color: isBlocked
                                    ? Colors.black
                                    : (isDangerous ? const Color(0xFFB71C1C) : cardColor),
                                elevation: (isDangerous || isBlocked) ? 0 : 4,
                                margin: const EdgeInsets.symmetric(horizontal: 15, vertical: 5),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(15),
                                  // Bordo rosso se bloccato, bianco se solo pericoloso
                                  side: isBlocked
                                      ? const BorderSide(color: Colors.redAccent, width: 2)
                                      : (isDangerous ? const BorderSide(color: Colors.white, width: 1) : BorderSide.none),
                                ),
                                child: ListTile(
                                  onTap: () {
                                    setState(() {
                                      // Conversione sicura da JSON a List<List<double>>
                                      if (item['polyline'] != null) {
                                        _selectedPolyline = (item['polyline'] as List).map((dynamic point) {
                                          return (point as List).map((dynamic coord) {
                                            return (coord as num).toDouble();
                                          }).toList();
                                        }).toList();
                                      } else {
                                        _selectedPolyline = [];
                                      }
                                    });

                                    ScaffoldMessenger.of(context).showSnackBar(
                                      SnackBar(content: Text("Visualizzazione percorso per: ${item['title']}")),
                                    );
                                  },
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
                                      // Sbarra il testo se è pericoloso o bloccato
                                      decoration: (isDangerous || isBlocked) ? TextDecoration.lineThrough : null,
                                    ),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  subtitle: Text(
                                    // Logica sottotitolo
                                    isBlocked
                                        ? "⚠️ DESTINAZIONE INACCESSIBILE"
                                        : (isDangerous
                                        ? "⚠️ DEVIAZIONE: +${(item['distance'] - item['dist_real']).toStringAsFixed(0)}m"
                                        : item['subtitle']),
                                    style: TextStyle(
                                      color: isBlocked ? Colors.redAccent : (isDangerous ? Colors.orangeAccent : Colors.white70),
                                      fontWeight: (isDangerous || isBlocked) ? FontWeight.bold : FontWeight.normal,
                                    ),
                                  ),
                                  trailing: Container(
                                    // Indicatore distanza e stato
                                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                                    decoration: BoxDecoration(
                                      color: isBlocked ? Colors.red.withValues(alpha: 0.3) : (isDangerous ? Colors.black45 : Colors.black26),
                                      borderRadius: BorderRadius.circular(10),
                                    ),
                                    child: Text(
                                      distStr,
                                      style: TextStyle(
                                        color: isBlocked ? Colors.redAccent : Colors.white,
                                        fontWeight: FontWeight.bold,
                                        fontSize: isBlocked ? 9 : 11,
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
