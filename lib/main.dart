import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'dart:convert';
import 'package:http/http.dart' as http;

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp();
  runApp(const MyApp());
}

// simple data model
class Item {
  final String id;
  final String ownerId;
  final String type; // "Lost" or "Found"
  final String title;
  final String description;
  final String location;
  final bool isClosed;
  Item({
    required this.id,
    required this.ownerId,
    required this.type,
    required this.title,
    required this.description,
    required this.location,
    required this.isClosed,
  });
  factory Item.fromDoc(DocumentSnapshot doc) {
    final data = doc.data() as Map<String, dynamic>;
    return Item(
      id: doc.id,
      ownerId: data['ownerId'] ?? '',
      type: data['type'] ?? 'Lost',
      title: data['title'] ?? '',
      description: data['description'] ?? '',
      location: data['location'] ?? '',
      isClosed: data['isClosed'] ?? false,
    );
  }
  Map<String, dynamic> toMap() {
    return {
      'ownerId': ownerId,
      'type': type,
      'title': title,
      'description': description,
      'location': location,
      'isClosed': isClosed,
      'createdAt': FieldValue.serverTimestamp(),
    };
  }
}

// Simple model to hold geocoding result
class GeoResult {
  final double lat;
  final double lon;
  final String displayName;

  GeoResult({required this.lat, required this.lon, required this.displayName});
}

// Call OpenStreetMap Nominatim geocoding API
Future<GeoResult?> geocodeLocation(String query) async {
  if (query.trim().isEmpty) return null;

  final url = Uri.parse(
    'https://nominatim.openstreetmap.org/search'
    '?q=${Uri.encodeComponent(query)}'
    '&format=json'
    '&limit=1',
  );

  final response = await http.get(
    url,
    headers: {
      // Nominatim requires a User-Agent header
      'User-Agent': 'campus-lost-found-app/1.0 (student project)',
    },
  );

  if (response.statusCode == 200) {
    final data = jsonDecode(response.body) as List<dynamic>;
    if (data.isEmpty) return null;

    final first = data[0] as Map<String, dynamic>;
    final lat = double.tryParse(first['lat'] ?? '') ?? 0.0;
    final lon = double.tryParse(first['lon'] ?? '') ?? 0.0;
    final displayName = first['display_name'] ?? 'Unknown location';

    return GeoResult(lat: lat, lon: lon, displayName: displayName);
  } else {
    throw Exception('Failed to geocode location');
  }
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Lost & Found',
      theme: ThemeData(useMaterial3: true, colorSchemeSeed: Colors.indigo),
      home: const AuthWrapper(),
    );
  }
}

// decides whether to show login or home
class AuthWrapper extends StatelessWidget {
  const AuthWrapper({super.key});
  @override
  Widget build(BuildContext context) {
    return StreamBuilder<User?>(
      stream: FirebaseAuth.instance.authStateChanges(),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }
        if (snapshot.hasData) {
          return const HomePage();
        } else {
          return const AuthPage();
        }
      },
    );
  }
}

// login / register page
class AuthPage extends StatefulWidget {
  const AuthPage({super.key});
  @override
  State<AuthPage> createState() => _AuthPageState();
}

class _AuthPageState extends State<AuthPage> {
  final emailCtrl = TextEditingController();
  final passCtrl = TextEditingController();
  bool loading = false;
  String? error;
  bool isLogin = true; // toggle login / register
  Future<void> submit() async {
    setState(() {
      loading = true;
      error = null;
    });
    try {
      if (isLogin) {
        await FirebaseAuth.instance.signInWithEmailAndPassword(
          email: emailCtrl.text.trim(),
          password: passCtrl.text.trim(),
        );
      } else {
        await FirebaseAuth.instance.createUserWithEmailAndPassword(
          email: emailCtrl.text.trim(),
          password: passCtrl.text.trim(),
        );
      }
    } on FirebaseAuthException catch (e) {
      setState(() {
        error = e.message;
      });
    } finally {
      if (mounted) {
        setState(() {
          loading = false;
        });
      }
    }
  }

  @override
  void dispose() {
    emailCtrl.dispose();
    passCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                isLogin ? 'Login' : 'Create Account',
                style: Theme.of(context).textTheme.headlineMedium,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 16),
              TextField(
                controller: emailCtrl,
                keyboardType: TextInputType.emailAddress,
                decoration: const InputDecoration(
                  labelText: 'Email',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: passCtrl,
                obscureText: true,
                decoration: const InputDecoration(
                  labelText: 'Password',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              if (error != null)
                Text(
                  error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              const SizedBox(height: 12),
              FilledButton(
                onPressed: loading ? null : submit,
                child: Text(
                  loading
                      ? (isLogin ? 'Signing in...' : 'Signing up...')
                      : (isLogin ? 'Sign In' : 'Sign Up'),
                ),
              ),
              TextButton(
                onPressed: loading
                    ? null
                    : () {
                        setState(() {
                          isLogin = !isLogin;
                          error = null;
                        });
                      },
                child: Text(
                  isLogin
                      ? 'Create a new account'
                      : 'Already have an account? Login',
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// home page: list of items + add + logout
class HomePage extends StatelessWidget {
  const HomePage({super.key});
  @override
  Widget build(BuildContext context) {
    final itemsRef = FirebaseFirestore.instance.collection('items');
    final user = FirebaseAuth.instance.currentUser;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Campus Lost & Found'),
        actions: [
          IconButton(
            onPressed: () async {
              await FirebaseAuth.instance.signOut();
            },
            icon: const Icon(Icons.logout),
          ),
        ],
      ),
      body: StreamBuilder<QuerySnapshot>(
        stream: itemsRef.orderBy('createdAt', descending: true).snapshots(),
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return Center(child: Text('Error: ${snapshot.error}'));
          }
          if (!snapshot.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          final docs = snapshot.data!.docs;
          if (docs.isEmpty) {
            return const Center(child: Text('No posts yet. Tap + to add one.'));
          }
          final items = docs.map((doc) => Item.fromDoc(doc)).toList();
          return ListView.separated(
            padding: const EdgeInsets.all(8),
            itemCount: items.length,
            separatorBuilder: (_, __) => const SizedBox(height: 8),
            itemBuilder: (context, index) {
              final item = items[index];
              final isOwner = user != null && user.uid == item.ownerId;
              return Card(
                child: ListTile(
                  title: Text(
                    '${item.type}: ${item.title}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: Text(
                    item.description,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  trailing: item.isClosed
                      ? const Text('Returned', style: TextStyle(fontSize: 12))
                      : isOwner
                      ? const Text('Mine', style: TextStyle(fontSize: 12))
                      : null,
                  onTap: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => DetailPage(itemId: item.id),
                      ),
                    );
                  },
                ),
              );
            },
          );
        },
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () {
          Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => const CreateItemPage()),
          );
        },
        child: const Icon(Icons.add),
      ),
    );
  }
}

// create item page
class CreateItemPage extends StatefulWidget {
  const CreateItemPage({super.key});
  @override
  State<CreateItemPage> createState() => _CreateItemPageState();
}

class _CreateItemPageState extends State<CreateItemPage> {
  String type = 'Lost';
  final titleCtrl = TextEditingController();
  final descCtrl = TextEditingController();
  final locCtrl = TextEditingController();
  bool saving = false;
  String? error;
  Future<void> saveItem() async {
    setState(() {
      error = null;
    });
    if (titleCtrl.text.trim().isEmpty || descCtrl.text.trim().isEmpty) {
      setState(() {
        error = 'Title and description are required';
      });
      return;
    }
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      setState(() {
        error = 'Not logged in';
      });
      return;
    }
    setState(() {
      saving = true;
    });
    final ref = FirebaseFirestore.instance.collection('items');
    try {
      final item = Item(
        id: '',
        ownerId: user.uid,
        type: type,
        title: titleCtrl.text.trim(),
        description: descCtrl.text.trim(),
        location: locCtrl.text.trim(),
        isClosed: false,
      );
      await ref.add(item.toMap());
      if (mounted) {
        Navigator.pop(context);
      }
    } catch (e) {
      setState(() {
        error = e.toString();
      });
    } finally {
      if (mounted) {
        setState(() {
          saving = false;
        });
      }
    }
  }

  @override
  void dispose() {
    titleCtrl.dispose();
    descCtrl.dispose();
    locCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('Create $type Item')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            DropdownButtonFormField<String>(
              value: type,
              decoration: const InputDecoration(
                labelText: 'Type',
                border: OutlineInputBorder(),
              ),
              items: const [
                DropdownMenuItem(value: 'Lost', child: Text('Lost')),
                DropdownMenuItem(value: 'Found', child: Text('Found')),
              ],
              onChanged: (v) {
                if (v != null) {
                  setState(() {
                    type = v;
                  });
                }
              },
            ),
            const SizedBox(height: 12),
            TextField(
              controller: titleCtrl,
              decoration: const InputDecoration(
                labelText: 'Title',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: descCtrl,
              maxLines: 3,
              decoration: const InputDecoration(
                labelText: 'Description',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: locCtrl,
              decoration: const InputDecoration(
                labelText: 'Where lost/found?',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            if (error != null)
              Text(
                error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            const SizedBox(height: 12),
            FilledButton(
              onPressed: saving ? null : saveItem,
              child: Text(saving ? 'Saving...' : 'Save'),
            ),
          ],
        ),
      ),
    );
  }
}

// item detail page
class DetailPage extends StatelessWidget {
  final String itemId;
  const DetailPage({super.key, required this.itemId});
  @override
  Widget build(BuildContext context) {
    final docRef = FirebaseFirestore.instance.collection('items').doc(itemId);
    final user = FirebaseAuth.instance.currentUser;
    return Scaffold(
      appBar: AppBar(title: const Text('Item details')),
      body: FutureBuilder<DocumentSnapshot>(
        future: docRef.get(),
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          if (!snapshot.hasData || !snapshot.data!.exists) {
            return const Center(child: Text('Item not found'));
          }
          final item = Item.fromDoc(snapshot.data!);
          final isOwner = user != null && user.uid == item.ownerId;
          return Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${item.type} item',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 8),
                Text(
                  item.title,
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
                const SizedBox(height: 8),
                if (item.location.isNotEmpty)
                  FutureBuilder<GeoResult?>(
                    // You can also append city/campus here for better accuracy
                    future: geocodeLocation(item.location),
                    builder: (context, geoSnapshot) {
                      if (geoSnapshot.connectionState ==
                          ConnectionState.waiting) {
                        return const Text('Looking up location on map...');
                      } else if (geoSnapshot.hasError) {
                        return const Text('Could not fetch map location');
                      } else if (!geoSnapshot.hasData ||
                          geoSnapshot.data == null) {
                        return const Text('No map data found for this place');
                      } else {
                        final geo = geoSnapshot.data!;
                        return Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Full address (from map):',
                              style: Theme.of(context).textTheme.titleSmall,
                            ),
                            Text(
                              geo.displayName,
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                            const SizedBox(height: 4),
                            Text(
                              'Latitude: ${geo.lat.toStringAsFixed(5)}, '
                              'Longitude: ${geo.lon.toStringAsFixed(5)}',
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                          ],
                        );
                      }
                    },
                  ),
                const SizedBox(height: 8),
                Text(item.description),
                const SizedBox(height: 16),
                if (item.isClosed)
                  Text(
                    'Status: Returned/Claimed',
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.primary,
                    ),
                  ),
                const Spacer(),
                if (!item.isClosed && isOwner)
                  MarkReturnedButton(docRef: docRef),
              ],
            ),
          );
        },
      ),
    );
  }
}

class MarkReturnedButton extends StatefulWidget {
  final DocumentReference docRef;
  const MarkReturnedButton({super.key, required this.docRef});
  @override
  State<MarkReturnedButton> createState() => _MarkReturnedButtonState();
}

class _MarkReturnedButtonState extends State<MarkReturnedButton> {
  bool loading = false;
  String? error;
  Future<void> markReturned() async {
    setState(() {
      loading = true;
      error = null;
    });
    try {
      await widget.docRef.update({'isClosed': true});
      if (mounted) {
        Navigator.pop(context);
      }
    } catch (e) {
      setState(() {
        error = e.toString();
      });
    } finally {
      if (mounted) {
        setState(() {
          loading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        FilledButton(
          onPressed: loading ? null : markReturned,
          child: Text(loading ? 'Marking...' : 'Mark as Returned/Claimed'),
        ),
        if (error != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
      ],
    );
  }
}
