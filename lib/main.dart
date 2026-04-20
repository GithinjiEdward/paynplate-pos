import 'package:flutter/material.dart';
import 'package:intl/intl.dart'; // For dates and currency
import 'package:sqflite/sqflite.dart'; // Local Database
import 'package:path/path.dart' as p; // For finding the database path
import 'package:fl_chart/fl_chart.dart'; // For the analytics charts
import 'package:firebase_core/firebase_core.dart'; // Required to start Firebase
import 'package:cloud_firestore/cloud_firestore.dart'; // Required for Cloud Sync
import 'package:firebase_auth/firebase_auth.dart'; // Firebase Authentication
import 'package:device_info_plus/device_info_plus.dart'; // Device locking
import 'package:path_provider/path_provider.dart'; // Local receipt storage
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import 'dart:io';
import 'dart:typed_data';
import 'dart:async';

// This is the entry point of your app
void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Initialize Firebase before the app starts
  try {
    await Firebase.initializeApp();
    debugPrint("Firebase connected successfully!");
  } catch (e) {
    debugPrint("Firebase connection failed: $e");
  }

  runApp(const EateryApp());
}

final GlobalKey<NavigatorState> appNavigatorKey = GlobalKey<NavigatorState>();
final GlobalKey<ScaffoldMessengerState> appScaffoldMessengerKey =
    GlobalKey<ScaffoldMessengerState>();

// --- 1. DATABASE HELPER (Full Business Multi-Tenant Version - UPGRADED) ---
class DatabaseHelper {
  static Database? _db;
  static final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  static final FirebaseAuth _auth = FirebaseAuth.instance;

  // 🔐 The Master Key: Locks the app session to the specific Business Account
  static String? currentBusinessId;
  static String? currentUserUid;
  static String? currentSessionToken;
  static String? currentDeviceId;
  static StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>?
  _sessionSubscription;

  static String normalizeLoginId(String raw) {
    return raw.trim().toLowerCase();
  }

  static String loginIdToEmail(String loginId) {
    return '${normalizeLoginId(loginId)}@paynplate.app';
  }

  static Future<String> getCurrentDeviceId() async {
    final deviceInfo = DeviceInfoPlugin();

    if (Platform.isAndroid) {
      final androidInfo = await deviceInfo.androidInfo;
      return androidInfo.id;
    }

    if (Platform.isIOS) {
      final iosInfo = await deviceInfo.iosInfo;
      return iosInfo.identifierForVendor ?? 'ios-unknown-device';
    }

    return 'unsupported-device';
  }

  static Future<Database> get database async {
    if (_db != null) return _db!;
    _db = await _initDb();
    return _db!;
  }

  static Future<Database> _initDb() async {
    String path = p.join(await getDatabasesPath(), 'eatery_pos_v4.db');
    return await openDatabase(
      path,
      version: 1,
      onCreate: (db, version) async {
        await db.execute(
          'CREATE TABLE users(id INTEGER PRIMARY KEY AUTOINCREMENT, uid TEXT, username TEXT, login_id TEXT UNIQUE, email TEXT, role TEXT, business_id TEXT)',
        );
        await db.execute(
          'CREATE TABLE products(id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT, price REAL, category TEXT, unit TEXT, stock REAL DEFAULT 0.0, business_id TEXT)',
        );
        await db.execute(
          'CREATE TABLE sales(id INTEGER PRIMARY KEY AUTOINCREMENT, date TEXT, total REAL, method TEXT, ref TEXT, search_date TEXT, sold_by TEXT, business_id TEXT)',
        );
        await db.execute(
          'CREATE TABLE sale_items(id INTEGER PRIMARY KEY AUTOINCREMENT, sale_id INTEGER, name TEXT, qty REAL, price REAL, unit TEXT, category TEXT, search_date TEXT, business_id TEXT)',
        );
      },
    );
  }

  // --- 🚀 Business Account BOOTSTRAP ---
  static Future<void> registerNewBusiness({
    required String bizId,
    required String bizName,
    required String adminUser,
    required String adminPass,
  }) async {
    final db = await database;

    final normalizedBizId = bizId.trim().toUpperCase();
    final normalizedUser = adminUser.trim().toLowerCase();
    final loginId = '$normalizedUser.${normalizedBizId.toLowerCase()}';
    final email = loginIdToEmail(loginId);

    UserCredential? cred;

    try {
      cred = await _auth.createUserWithEmailAndPassword(
        email: email,
        password: adminPass.trim(),
      );

      final user = cred.user;
      if (user == null) {
        throw Exception(
          'Account creation failed. No authenticated user returned.',
        );
      }

      await user.getIdToken(true);
      await user.reload();

      final uid = user.uid;
      final deviceId = await getCurrentDeviceId();

      final profileData = {
        'uid': uid,
        'username': normalizedUser,
        'login_id': loginId,
        'email': email,
        'role': 'admin',
        'business_id': normalizedBizId,
        'status': 'active',
        'device_id': deviceId,
        'device_locked': true,
        'active_device_id': '',
        'is_logged_in': false,
        'session_token': '',
        'created_at': FieldValue.serverTimestamp(),
      };

      final bizMetadata = {
        'business_name': bizName.trim(),
        'created_at': FieldValue.serverTimestamp(),
        'status': 'active',
        'business_id': normalizedBizId,
        'owner_uid': uid,
      };

      try {
        await _firestore.collection('staff_profiles').doc(uid).set(profileData);
        debugPrint('staff_profiles created for $uid');
      } catch (e) {
        debugPrint('staff_profiles create failed: $e');
        rethrow;
      }

      try {
        await _firestore
            .collection('businesses')
            .doc(normalizedBizId)
            .set(bizMetadata);
        debugPrint('business created for $normalizedBizId');
      } catch (e) {
        debugPrint('business create failed: $e');
        rethrow;
      }

      try {
        await _firestore
            .collection('businesses')
            .doc(normalizedBizId)
            .collection('staff')
            .doc(uid)
            .set(profileData);
        debugPrint('business staff mirror created for $uid');
      } catch (e) {
        debugPrint('business staff mirror create failed: $e');
        rethrow;
      }

      await db.insert('users', {
        'uid': uid,
        'username': normalizedUser,
        'login_id': loginId,
        'email': email,
        'role': 'admin',
        'business_id': normalizedBizId,
      }, conflictAlgorithm: ConflictAlgorithm.replace);

      currentBusinessId = normalizedBizId;
      currentUserUid = uid;
      currentDeviceId = deviceId;
    } on FirebaseAuthException catch (e) {
      debugPrint('Bootstrap Auth Error: ${e.code} | ${e.message}');
      if (e.code == 'email-already-in-use') {
        throw Exception(
          'This admin username and Business ID combination was already used before, or the registration attempt partially completed earlier. Try a different username or delete the old Authentication user.',
        );
      }
      rethrow;
    } catch (e) {
      debugPrint('Bootstrap Error: $e');

      try {
        if (cred?.user != null) {
          await cred!.user!.delete();
        }
      } catch (deleteError) {
        debugPrint('Bootstrap rollback delete failed: $deleteError');
      }

      rethrow;
    }
  }

  static Future<Map<String, dynamic>> _acquireDeviceSession({
    required String uid,
    required String businessId,
    required String deviceId,
  }) async {
    final profileRef = _firestore.collection('staff_profiles').doc(uid);
    final staffRef = _firestore
        .collection('businesses')
        .doc(businessId)
        .collection('staff')
        .doc(uid);
    final deviceRef = _firestore.collection('device_registry').doc(deviceId);
    final sessionToken =
        'session_${DateTime.now().millisecondsSinceEpoch}_$uid';

    await _firestore.runTransaction((txn) async {
      final profileSnap = await txn.get(profileRef);
      if (!profileSnap.exists) {
        throw Exception('Staff profile not found.');
      }

      final profileData = profileSnap.data() ?? <String, dynamic>{};
      final existingBusinessId = (profileData['business_id'] ?? '')
          .toString()
          .trim()
          .toUpperCase();
      if (existingBusinessId != businessId) {
        throw Exception('Business account mismatch.');
      }

      final deviceSnap = await txn.get(deviceRef);
      final deviceData = deviceSnap.data() ?? <String, dynamic>{};
      final deviceBusinessId = (deviceData['business_id'] ?? businessId)
          .toString()
          .trim()
          .toUpperCase();
      if (deviceSnap.exists && deviceBusinessId != businessId) {
        throw Exception('This device is assigned to a different business.');
      }

      final assignedUids = List<String>.from(
        deviceData['assigned_uids'] ?? const <String>[],
      );
      final activeUid = (deviceData['active_uid'] ?? '').toString();

      if (activeUid.isNotEmpty && activeUid != uid) {
        throw Exception(
          'Another account is currently active on this device. Please log out first.',
        );
      }

      if (!assignedUids.contains(uid) && assignedUids.length >= 2) {
        throw Exception(
          'This device already has the maximum of 2 accounts assigned.',
        );
      }

      if (!assignedUids.contains(uid)) {
        assignedUids.add(uid);
      }

      final previousDeviceId = (profileData['device_id'] ?? '').toString();
      if (previousDeviceId.isNotEmpty && previousDeviceId != deviceId) {
        final previousDeviceRef = _firestore
            .collection('device_registry')
            .doc(previousDeviceId);
        final previousDeviceSnap = await txn.get(previousDeviceRef);
        if (previousDeviceSnap.exists) {
          final previousDeviceData =
              previousDeviceSnap.data() ?? <String, dynamic>{};
          final previousAssignedUids = List<String>.from(
            previousDeviceData['assigned_uids'] ?? const <String>[],
          );
          previousAssignedUids.remove(uid);
          final previousActiveUid = (previousDeviceData['active_uid'] ?? '')
              .toString();

          txn.set(previousDeviceRef, {
            'device_id': previousDeviceId,
            'business_id': businessId,
            'assigned_uids': previousAssignedUids,
            'active_uid': previousActiveUid == uid ? '' : previousActiveUid,
            'updated_at': FieldValue.serverTimestamp(),
          }, SetOptions(merge: true));
        }
      }

      txn.set(deviceRef, {
        'device_id': deviceId,
        'business_id': businessId,
        'assigned_uids': assignedUids,
        'active_uid': uid,
        'updated_at': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));

      final sessionFields = {
        'device_id': deviceId,
        'device_locked': true,
        'active_device_id': deviceId,
        'is_logged_in': true,
        'session_token': sessionToken,
        'last_login_at': FieldValue.serverTimestamp(),
      };

      txn.set(profileRef, sessionFields, SetOptions(merge: true));
      txn.set(staffRef, sessionFields, SetOptions(merge: true));
    });

    return {'session_token': sessionToken, 'device_id': deviceId};
  }

  static Future<void> releaseActiveSession({
    bool preserveAccountAssignment = true,
  }) async {
    final uid = currentUserUid ?? _auth.currentUser?.uid;
    final businessId = currentBusinessId;
    final deviceId = currentDeviceId ?? await getCurrentDeviceId();

    if (uid == null || businessId == null || businessId.isEmpty) {
      return;
    }

    final profileRef = _firestore.collection('staff_profiles').doc(uid);
    final staffRef = _firestore
        .collection('businesses')
        .doc(businessId)
        .collection('staff')
        .doc(uid);
    final deviceRef = _firestore.collection('device_registry').doc(deviceId);

    await _firestore.runTransaction((txn) async {
      final deviceSnap = await txn.get(deviceRef);
      if (deviceSnap.exists) {
        final deviceData = deviceSnap.data() ?? <String, dynamic>{};
        final assignedUids = List<String>.from(
          deviceData['assigned_uids'] ?? const <String>[],
        );
        final activeUid = (deviceData['active_uid'] ?? '').toString();

        if (!preserveAccountAssignment) {
          assignedUids.remove(uid);
        }

        txn.set(deviceRef, {
          'device_id': deviceId,
          'business_id': businessId,
          'assigned_uids': assignedUids,
          'active_uid': activeUid == uid ? '' : activeUid,
          'updated_at': FieldValue.serverTimestamp(),
        }, SetOptions(merge: true));
      }

      final clearFields = {
        'active_device_id': '',
        'is_logged_in': false,
        'session_token': '',
        'last_logout_at': FieldValue.serverTimestamp(),
      };

      txn.set(profileRef, clearFields, SetOptions(merge: true));
      txn.set(staffRef, clearFields, SetOptions(merge: true));
    });
  }

  static Future<void> logoutCurrentUser({
    bool releaseDeviceSession = true,
    bool preserveAccountAssignment = true,
  }) async {
    await stopSessionMonitor();

    if (releaseDeviceSession) {
      try {
        await releaseActiveSession(
          preserveAccountAssignment: preserveAccountAssignment,
        );
      } catch (e) {
        debugPrint('Release session failed: $e');
      }
    }

    await _auth.signOut();
    currentBusinessId = null;
    currentUserUid = null;
    currentSessionToken = null;
    currentDeviceId = null;
  }

  static void startSessionMonitor({
    required VoidCallback onSessionInvalidated,
  }) {
    stopSessionMonitor();

    final uid = currentUserUid;
    if (uid == null || uid.isEmpty) {
      return;
    }

    bool hasSeenServerSnapshot = false;

    _sessionSubscription = _firestore
        .collection('staff_profiles')
        .doc(uid)
        .snapshots(includeMetadataChanges: true)
        .listen((snapshot) {
          if (!snapshot.exists) {
            if (hasSeenServerSnapshot) {
              onSessionInvalidated();
            }
            return;
          }

          if (snapshot.metadata.isFromCache && !hasSeenServerSnapshot) {
            return;
          }

          if (!snapshot.metadata.isFromCache) {
            hasSeenServerSnapshot = true;
          }

          final data = snapshot.data() ?? <String, dynamic>{};
          final remoteToken = (data['session_token'] ?? '').toString();
          final remoteActiveDeviceId = (data['active_device_id'] ?? '')
              .toString();
          final remoteLoggedIn = (data['is_logged_in'] ?? false) == true;

          if (!hasSeenServerSnapshot) {
            return;
          }

          if (!remoteLoggedIn ||
              remoteToken.isEmpty ||
              remoteToken != currentSessionToken ||
              remoteActiveDeviceId != currentDeviceId) {
            onSessionInvalidated();
          }
        });
  }

  static Future<void> stopSessionMonitor() async {
    await _sessionSubscription?.cancel();
    _sessionSubscription = null;
  }

  // --- ☁️ CLOUD SYNC PULL ---
  static Future<void> pullCloudProducts() async {
    if (currentBusinessId == null) return;
    try {
      final snapshot = await _firestore
          .collection('businesses')
          .doc(currentBusinessId!)
          .collection('products')
          .get();
      final db = await database;

      await db.transaction((txn) async {
        await txn.delete(
          'products',
          where: 'business_id = ?',
          whereArgs: [currentBusinessId],
        );
        for (var doc in snapshot.docs) {
          await txn.insert(
            'products',
            doc.data(),
            conflictAlgorithm: ConflictAlgorithm.replace,
          );
        }
      });
    } catch (e) {
      debugPrint("Cloud Products Pull Error: $e");
    }
  }

  static Future<void> pullCloudSales() async {
    if (currentBusinessId == null) return;
    try {
      final db = await database;
      final snapshot = await _firestore
          .collection('businesses')
          .doc(currentBusinessId!)
          .collection('sales')
          .get();

      await db.transaction((txn) async {
        await txn.delete(
          'sales',
          where: 'business_id = ?',
          whereArgs: [currentBusinessId],
        );
        await txn.delete(
          'sale_items',
          where: 'business_id = ?',
          whereArgs: [currentBusinessId],
        );

        for (var doc in snapshot.docs) {
          Map<String, dynamic> saleData = doc.data();
          List<dynamic> items = saleData['items'] ?? [];

          Map<String, dynamic> cleanSale = Map.from(saleData)
            ..remove('items')
            ..remove('server_timestamp');

          int saleId = await txn.insert(
            'sales',
            cleanSale,
            conflictAlgorithm: ConflictAlgorithm.replace,
          );

          for (var item in items) {
            Map<String, dynamic> itemData = Map<String, dynamic>.from(item);
            itemData['sale_id'] = saleId;
            itemData['business_id'] = currentBusinessId;
            await txn.insert(
              'sale_items',
              itemData,
              conflictAlgorithm: ConflictAlgorithm.replace,
            );
          }
        }
      });
    } catch (e) {
      debugPrint("Sales Pull Error: $e");
    }
  }

  // --- 🔐 STAFF & USER MANAGEMENT ---
  static Future<Map<String, dynamic>?> loginUser(
    String loginIdInput,
    String pass,
  ) async {
    final db = await database;

    try {
      final loginId = normalizeLoginId(loginIdInput);
      final email = loginIdToEmail(loginId);

      final cred = await _auth.signInWithEmailAndPassword(
        email: email,
        password: pass.trim(),
      );

      final uid = cred.user!.uid;
      final profileSnap = await _firestore
          .collection('staff_profiles')
          .doc(uid)
          .get();

      if (!profileSnap.exists) {
        await _auth.signOut();
        return null;
      }

      final profile = profileSnap.data()!;
      if ((profile['status'] ?? 'active') != 'active') {
        await _auth.signOut();
        return null;
      }

      final currentDevice = await getCurrentDeviceId();
      final bizId = (profile['business_id'] as String).trim().toUpperCase();
      await _acquireDeviceSession(
        uid: uid,
        businessId: bizId,
        deviceId: currentDevice,
      );

      final freshProfileSnap = await _firestore
          .collection('staff_profiles')
          .doc(uid)
          .get();

      if (!freshProfileSnap.exists) {
        await _auth.signOut();
        return null;
      }

      final freshProfile = freshProfileSnap.data()!;
      profile
        ..clear()
        ..addAll(freshProfile);

      await db.insert('users', {
        'uid': uid,
        'username': profile['username'],
        'login_id': profile['login_id'],
        'email': profile['email'],
        'role': profile['role'],
        'business_id': bizId,
      }, conflictAlgorithm: ConflictAlgorithm.replace);

      currentBusinessId = bizId;
      currentUserUid = uid;
      currentSessionToken = profile['session_token']?.toString();
      currentDeviceId = currentDevice;
      return profile;
    } on FirebaseAuthException catch (e) {
      debugPrint("Login error: ${e.code} | ${e.message}");
      return null;
    } catch (e) {
      debugPrint("Login error: $e");
      await _auth.signOut();
      rethrow;
    }
  }

  static Future<int> addUser(String user, String pass, String role) async {
    if (currentBusinessId == null) {
      throw Exception("No active business account.");
    }

    final db = await database;
    final username = user.trim().toLowerCase();
    final bizId = currentBusinessId!.trim().toUpperCase();
    final loginId = '$username.${bizId.toLowerCase()}';
    final email = loginIdToEmail(loginId);

    if (username.isEmpty) {
      throw Exception('Username is required.');
    }

    if (pass.trim().length < 6) {
      throw Exception('Password must be at least 6 characters.');
    }

    final localExisting = await db.query(
      'users',
      where: 'login_id = ? AND business_id = ?',
      whereArgs: [loginId, bizId],
      limit: 1,
    );
    if (localExisting.isNotEmpty) {
      throw Exception(
        'That username already exists for this business. Use a different username.',
      );
    }

    final remoteExisting = await _firestore
        .collection('businesses')
        .doc(bizId)
        .collection('staff')
        .where('login_id', isEqualTo: loginId)
        .limit(1)
        .get();
    if (remoteExisting.docs.isNotEmpty) {
      throw Exception(
        'That username already exists for this business. Use a different username.',
      );
    }

    FirebaseApp? secondaryApp;
    FirebaseAuth? secondaryAuth;
    User? createdUser;

    try {
      final defaultApp = Firebase.app();
      secondaryApp = await Firebase.initializeApp(
        name: 'staffCreator-${DateTime.now().millisecondsSinceEpoch}',
        options: defaultApp.options,
      );
      secondaryAuth = FirebaseAuth.instanceFor(app: secondaryApp);

      final cred = await secondaryAuth.createUserWithEmailAndPassword(
        email: email,
        password: pass.trim(),
      );
      createdUser = cred.user;

      if (createdUser == null) {
        throw Exception('Failed to create the staff authentication account.');
      }

      final uid = createdUser.uid;
      final profile = {
        'uid': uid,
        'username': username,
        'login_id': loginId,
        'email': email,
        'role': role,
        'business_id': bizId,
        'status': 'active',
        'device_id': '',
        'device_locked': true,
        'active_device_id': '',
        'is_logged_in': false,
        'session_token': '',
        'created_at': FieldValue.serverTimestamp(),
      };

      await _firestore.collection('staff_profiles').doc(uid).set(profile);
      await _firestore
          .collection('businesses')
          .doc(bizId)
          .collection('staff')
          .doc(uid)
          .set(profile);

      return await db.insert('users', {
        'uid': uid,
        'username': username,
        'login_id': loginId,
        'email': email,
        'role': role,
        'business_id': bizId,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    } on FirebaseAuthException catch (e) {
      debugPrint('Add user auth failed: ${e.code} | ${e.message}');
      if (e.code == 'email-already-in-use') {
        throw Exception(
          'This username already has an auth account for this business, or an earlier registration partially completed. Use a different username, or delete the old auth user from Firebase Authentication first.',
        );
      }
      if (e.code == 'weak-password') {
        throw Exception('Password is too weak. Use at least 6 characters.');
      }
      throw Exception(e.message ?? 'Failed to create staff account.');
    } catch (e) {
      debugPrint("Add user failed: $e");

      if (createdUser != null) {
        try {
          await createdUser.delete();
        } catch (deleteError) {
          debugPrint('Staff auth rollback delete failed: $deleteError');
        }
      }

      rethrow;
    } finally {
      try {
        await secondaryAuth?.signOut();
      } catch (_) {}
      try {
        await secondaryApp?.delete();
      } catch (_) {}
    }
  }

  static Future<List<Map<String, dynamic>>> getAllUsers() async {
    final db = await database;
    return await db.query(
      'users',
      where: 'business_id = ?',
      whereArgs: [currentBusinessId],
      orderBy: 'role ASC',
    );
  }

  static Future<void> deleteUser(int id) async {
    final db = await database;
    final res = await db.query('users', where: 'id = ?', whereArgs: [id]);

    if (res.isEmpty) return;

    final row = res.first;
    final uid = row['uid']?.toString();
    final bizId = row['business_id']?.toString() ?? currentBusinessId;

    if (uid != null && uid.isNotEmpty) {
      try {
        await _firestore.collection('staff_profiles').doc(uid).delete();
      } catch (e) {
        debugPrint('Delete staff profile failed: $e');
      }

      if (bizId != null && bizId.isNotEmpty) {
        try {
          await _firestore
              .collection('businesses')
              .doc(bizId)
              .collection('staff')
              .doc(uid)
              .delete();
        } catch (e) {
          debugPrint('Delete business staff doc failed: $e');
        }
      }
    }

    await db.delete('users', where: 'id = ?', whereArgs: [id]);
  }

  static Future<void> sendPasswordResetForUsername(String username) async {
    final db = await database;
    final res = await db.query(
      'users',
      columns: ['email', 'login_id'],
      where: 'username = ?',
      whereArgs: [username.toLowerCase()],
      limit: 1,
    );

    if (res.isEmpty) {
      throw Exception('No staff account found for $username.');
    }

    final email = res.first['email']?.toString();

    if (email == null || email.isEmpty || email.endsWith('@paynplate.app')) {
      throw Exception(
        'This staff login uses an internal auth email. Reset it from your admin backend or Firebase Console for now.',
      );
    }

    await FirebaseAuth.instance.sendPasswordResetEmail(email: email);
  }

  static Future<void> updatePassword(
    String username,
    String newPassword,
  ) async {
    throw Exception(
      'Direct password change is disabled. Use the reset-password flow.',
    );
  }

  // --- 📦 INVENTORY ---
  static Future<List<Map<String, dynamic>>> getProducts() async {
    final db = await database;
    return await db.query(
      'products',
      where: 'business_id = ?',
      whereArgs: [currentBusinessId],
      orderBy: 'name ASC',
    );
  }

  static Future<void> addProduct(
    String n,
    double p,
    String c,
    String u,
    double s,
  ) async {
    if (currentBusinessId == null) return;
    final db = await database;
    final data = {
      'name': n,
      'price': p,
      'category': c,
      'unit': u,
      'stock': s,
      'business_id': currentBusinessId,
    };
    await db.insert('products', data);
    await _firestore
        .collection('businesses')
        .doc(currentBusinessId!)
        .collection('products')
        .doc(n)
        .set(data);
  }

  static Future<void> updateProduct(
    int id,
    String n,
    double p,
    String c,
    String u,
    double s,
  ) async {
    if (currentBusinessId == null) return;
    final db = await database;
    final data = {
      'name': n,
      'price': p,
      'category': c,
      'unit': u,
      'stock': s,
      'business_id': currentBusinessId,
    };
    await db.update('products', data, where: 'id = ?', whereArgs: [id]);
    await _firestore
        .collection('businesses')
        .doc(currentBusinessId!)
        .collection('products')
        .doc(n)
        .set(data);
  }

  static Future<void> deleteProduct(int id) async {
    final db = await database;
    var res = await db.query('products', where: 'id = ?', whereArgs: [id]);
    if (res.isNotEmpty && currentBusinessId != null) {
      String name = res.first['name'] as String;
      await _firestore
          .collection('businesses')
          .doc(currentBusinessId!)
          .collection('products')
          .doc(name)
          .delete();
    }
    await db.delete('products', where: 'id = ?', whereArgs: [id]);
  }

  // --- 💰 SALES ---
  static Future<int> insertSale(
    Map<String, dynamic> sale,
    List<Map<String, dynamic>> items,
    String sellerName,
  ) async {
    final db = await database;
    if (currentBusinessId == null)
      throw Exception("No active business account.");

    String sDate = DateFormat('yyyy-MM-dd').format(DateTime.now());
    int saleId = 0;

    await db.transaction((txn) async {
      Map<String, dynamic> finalSaleData = Map.from(sale);
      finalSaleData['search_date'] = sDate;
      finalSaleData['sold_by'] = sellerName;
      finalSaleData['business_id'] = currentBusinessId;
      saleId = await txn.insert('sales', finalSaleData);

      for (var item in items) {
        double qty = double.tryParse(item['qty'].toString()) ?? 1.0;
        await txn.insert('sale_items', {
          'sale_id': saleId,
          'name': item['name'],
          'qty': qty,
          'price': item['price'],
          'unit': item['unit'],
          'category': item['category'],
          'search_date': sDate,
          'business_id': currentBusinessId,
        });
        if (["Raw Meat", "Roasted", "Drinks"].contains(item['category'])) {
          await txn.rawUpdate(
            'UPDATE products SET stock = stock - ? WHERE name = ? AND business_id = ?',
            [qty, item['name'], currentBusinessId],
          );
        }
      }
    });
    return saleId;
  }

  static Future<void> syncSaleToCloud(int localSaleId) async {
    final db = await database;
    if (currentBusinessId == null) return;

    final saleQuery = await db.query(
      'sales',
      where: 'id = ?',
      whereArgs: [localSaleId],
    );
    final itemsQuery = await db.query(
      'sale_items',
      where: 'sale_id = ?',
      whereArgs: [localSaleId],
    );

    if (saleQuery.isEmpty) return;
    final saleData = saleQuery.first;

    await _firestore
        .collection('businesses')
        .doc(currentBusinessId!)
        .collection('sales')
        .doc(saleData['ref'] as String)
        .set({
          ...saleData,
          'items': itemsQuery,
          'server_timestamp': FieldValue.serverTimestamp(),
        });
  }

  static Future<List<Map<String, dynamic>>> getDailySales() async {
    final db = await database;
    return await db.query(
      'sales',
      where: 'business_id = ?',
      whereArgs: [currentBusinessId],
      orderBy: 'id DESC',
    );
  }

  static Future<List<Map<String, dynamic>>> getSaleItems(int saleId) async {
    final db = await database;
    return await db.query(
      'sale_items',
      where: 'sale_id = ?',
      whereArgs: [saleId],
    );
  }

  static Future<String?> getLastSalesId() async {
    final db = await database;
    var res = await db.query(
      "sales",
      columns: ["ref"],
      where: 'business_id = ?',
      whereArgs: [currentBusinessId],
      orderBy: "id DESC",
      limit: 1,
    );
    return res.isNotEmpty ? res.first["ref"] as String? : null;
  }

  // --- 💰 UPGRADED ANALYTICS QUERY ---
  static Future<List<Map<String, dynamic>>> getRevenueSummary(
    String type, {
    DateTimeRange? range,
  }) async {
    final db = await database;
    if (currentBusinessId == null) return [];

    String grouping = type == "Monthly"
        ? "STRFTIME('%Y-%m-01', search_date)"
        : "search_date";
    String whereClause = "WHERE business_id = ?";
    List<dynamic> args = [currentBusinessId];

    if (range != null) {
      whereClause += " AND search_date BETWEEN ? AND ?";
      args.addAll([
        DateFormat('yyyy-MM-dd').format(range.start),
        DateFormat('yyyy-MM-dd').format(range.end),
      ]);
    }

    return await db.rawQuery(
      'SELECT $grouping as label, SUM(total) as revenue '
      'FROM sales $whereClause '
      'GROUP BY label '
      'ORDER BY label ASC '
      'LIMIT 10',
      args,
    );
  }
}

// --- 2. MAIN APP & LOGIN SCREEN ---
class EateryApp extends StatelessWidget {
  const EateryApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      navigatorKey: appNavigatorKey,
      scaffoldMessengerKey: appScaffoldMessengerKey,
      debugShowCheckedModeBanner: false,
      title: 'PayNPlate POS',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.orange),
        useMaterial3: true,
        inputDecorationTheme: InputDecorationTheme(
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
          filled: true,
          fillColor: Colors.white,
        ),
      ),
      home: const LoginScreen(),
    );
  }
}

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final TextEditingController _uC = TextEditingController();
  final TextEditingController _pC = TextEditingController();
  bool _isLoading = false;
  String _loadingStatus = "Authenticating...";

  void _handleLogin() async {
    String loginId = _uC.text.trim().toLowerCase();
    String password = _pC.text.trim();

    if (loginId.isEmpty || password.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text("Please enter both login ID and password"),
        ),
      );
      return;
    }

    setState(() {
      _isLoading = true;
      _loadingStatus = "Logging in...";
    });

    try {
      final userAccount = await DatabaseHelper.loginUser(loginId, password);

      if (userAccount != null) {
        setState(() => _loadingStatus = "Syncing Inventory...");
        try {
          await DatabaseHelper.pullCloudProducts().timeout(
            const Duration(seconds: 10),
            onTimeout: () => debugPrint("Sync timeout."),
          );
        } catch (e) {
          debugPrint("Sync Error: $e");
        }

        setState(() => _isLoading = false);
        if (!mounted) {
          return;
        }

        Navigator.pushReplacement(
          context,
          MaterialPageRoute(
            builder: (c) => POSScreen(
              currentUserName:
                  userAccount['username'] ?? loginId.split('.').first,
              currentUserRole: userAccount['role'] ?? "staff",
            ),
          ),
        );
      } else {
        setState(() => _isLoading = false);
        if (!mounted) {
          return;
        }
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text("Invalid Login ID or Password."),
            backgroundColor: Colors.redAccent,
          ),
        );
      }
    } catch (e) {
      setState(() => _isLoading = false);
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text("Critical Error: $e")));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        width: double.infinity,
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Colors.orange.shade100, Colors.white],
          ),
        ),
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(30),
            child: Column(
              children: [
                Image.asset('assets/dine.png', width: 66, height: 66),
                const SizedBox(height: 15),
                const Text(
                  "PayNPlate EATERY",
                  style: TextStyle(
                    fontSize: 32,
                    fontWeight: FontWeight.bold,
                    color: Colors.orange,
                  ),
                ),
                const Text(
                  "SMOOTH PAYMENTS FOR BUSY KITCHENS",
                  style: TextStyle(
                    color: Colors.grey,
                    fontSize: 11,
                    letterSpacing: 1.5,
                  ),
                ),
                const SizedBox(height: 40),
                TextField(
                  controller: _uC,
                  decoration: const InputDecoration(
                    labelText: "Login ID",
                    hintText: "e.g. eddie.bgb04",
                    prefixIcon: Icon(Icons.person),
                  ),
                ),
                const SizedBox(height: 20),
                TextField(
                  controller: _pC,
                  obscureText: true,
                  decoration: const InputDecoration(
                    labelText: "Password",
                    prefixIcon: Icon(Icons.lock),
                  ),
                ),
                const SizedBox(height: 30),
                ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    minimumSize: const Size(double.infinity, 60),
                    backgroundColor: Colors.orange,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(15),
                    ),
                  ),
                  onPressed: _isLoading ? null : _handleLogin,
                  child: _isLoading
                      ? Text(_loadingStatus)
                      : const Text(
                          "LOGIN TO SYSTEM",
                          style: TextStyle(fontWeight: FontWeight.bold),
                        ),
                ),

                const SizedBox(height: 30),
                // --- REGISTRATION LINK ---
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Text("New Business? "),
                    TextButton(
                      onPressed: () => Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (c) => const BusinessRegistrationScreen(),
                        ),
                      ),
                      child: const Text(
                        "Register Your Business",
                        style: TextStyle(
                          color: Colors.orange,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 30),
                const Text(
                  "Managed by Munward Consulting Platform\n            • Reliable • Secure • Scalable.",
                  style: TextStyle(fontSize: 11, color: Colors.blueGrey),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// --- NEW CLASS: BUSINESS REGISTRATION SCREEN ---
class BusinessRegistrationScreen extends StatefulWidget {
  const BusinessRegistrationScreen({super.key});

  @override
  State<BusinessRegistrationScreen> createState() =>
      _BusinessRegistrationScreenState();
}

class _BusinessRegistrationScreenState
    extends State<BusinessRegistrationScreen> {
  final TextEditingController _bizId = TextEditingController();
  final TextEditingController _bizName = TextEditingController();
  final TextEditingController _adminUser = TextEditingController();
  final TextEditingController _adminPass = TextEditingController();
  bool _isLoading = false;

  void _register() async {
    if (_bizId.text.isEmpty ||
        _adminUser.text.isEmpty ||
        _adminPass.text.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text("All fields are required!")));
      return;
    }

    setState(() => _isLoading = true);
    try {
      // ✅ Using Named Parameters as required by your DatabaseHelper.registerNewBusiness
      await DatabaseHelper.registerNewBusiness(
        bizId: _bizId.text.trim().toUpperCase(),
        bizName: _bizName.text.trim(),
        adminUser: _adminUser.text.trim().toLowerCase(),
        adminPass: _adminPass.text.trim(),
      );

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("Account Created! You can now login.")),
        );
        Navigator.pop(context); // Go back to login screen
      }
    } catch (e) {
      if (mounted)
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text("Failed: $e")));
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("Register New Business")),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(25),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              "Business Identity",
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
                color: Colors.orange,
              ),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _bizId,
              decoration: const InputDecoration(
                labelText: "Unique Business ID (e.g. BGB01)",
                helperText: "This ID connects your staff and data",
              ),
            ),
            const SizedBox(height: 15),
            TextField(
              controller: _bizName,
              decoration: const InputDecoration(labelText: "Business Name"),
            ),
            const SizedBox(height: 30),
            const Text(
              "Admin Account Setup",
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
                color: Colors.orange,
              ),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _adminUser,
              decoration: const InputDecoration(
                labelText: "Admin Username",
                helperText: "Example: eddie → login becomes eddie.bgb04",
              ),
            ),
            const SizedBox(height: 15),
            TextField(
              controller: _adminPass,
              obscureText: true,
              decoration: const InputDecoration(labelText: "Admin Password"),
            ),
            const SizedBox(height: 40),
            _isLoading
                ? const Center(child: CircularProgressIndicator())
                : ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      minimumSize: const Size(double.infinity, 60),
                      backgroundColor: Colors.orange,
                    ),
                    onPressed: _register,
                    child: const Text(
                      "CREATE BUSINESS ACCOUNT",
                      style: TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
          ],
        ),
      ),
    );
  }
}

// --- 3. POS SCREEN (Complete Upgraded & Debugged Version) ---
class POSScreen extends StatefulWidget {
  final String currentUserName;
  final String currentUserRole;

  const POSScreen({
    super.key,
    required this.currentUserName,
    required this.currentUserRole,
  });

  @override
  State<POSScreen> createState() => _POSScreenState();
}

class _POSScreenState extends State<POSScreen> {
  String selectedCat = "Cooked";
  List<Map<String, dynamic>> cart = [];
  bool _isSyncing = false;

  @override
  void initState() {
    super.initState();
    _checkAndSyncInventory();
    DatabaseHelper.startSessionMonitor(
      onSessionInvalidated: _handleSessionInvalidated,
    );
  }

  Future<void> _handleSessionInvalidated() async {
    await DatabaseHelper.stopSessionMonitor();
    await DatabaseHelper.logoutCurrentUser(releaseDeviceSession: false);

    final navigator = appNavigatorKey.currentState;
    final context = appNavigatorKey.currentContext;
    if (navigator == null || context == null) {
      return;
    }

    navigator.pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => const LoginScreen()),
      (route) => false,
    );

    appScaffoldMessengerKey.currentState?.showSnackBar(
      const SnackBar(
        content: Text(
          'This account was signed in on another device, so this session was ended.',
        ),
        backgroundColor: Colors.redAccent,
      ),
    );
  }

  @override
  void dispose() {
    DatabaseHelper.stopSessionMonitor();
    super.dispose();
  }

  Future<void> _checkAndSyncInventory() async {
    final products = await DatabaseHelper.getProducts();
    if (products.isEmpty) {
      setState(() => _isSyncing = true);
      try {
        await DatabaseHelper.pullCloudProducts();
      } catch (e) {
        debugPrint("Auto-sync failed: $e");
      } finally {
        if (mounted) setState(() => _isSyncing = false);
      }
    }
  }

  double get total =>
      cart.fold(0, (totalSum, i) => totalSum + (i['price'] as double));

  Future<String> _generateSequentialId() async {
    String? lastId = await DatabaseHelper.getLastSalesId();
    int nextNum = 1;
    if (lastId != null && lastId.contains('-')) {
      String lastNumStr = lastId.split('-').last;
      nextNum = (int.tryParse(lastNumStr) ?? 0) + 1;
    }
    final businessId = (DatabaseHelper.currentBusinessId ?? 'BIZ')
        .trim()
        .toUpperCase();
    return '$businessId-${nextNum.toString().padLeft(3, '0')}';
  }

  void _removeFromCart(int index) {
    setState(() {
      cart.removeAt(index);
    });
  }

  @override
  Widget build(BuildContext context) {
    final bool isAdmin = widget.currentUserRole == 'admin';

    return Scaffold(
      appBar: AppBar(
        title: const Text(
          "PayNPlate POS",
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
        backgroundColor: Colors.orange,
        foregroundColor: Colors.white,
        elevation: 0,
      ),

      drawer: Drawer(
        child: Column(
          children: [
            // 1. CENTERED BRANDING HEADER
            DrawerHeader(
              decoration: const BoxDecoration(color: Colors.orange),
              child: Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Text(
                      "PayNPlate",
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 28,
                        fontWeight: FontWeight.bold,
                        letterSpacing: 1.2,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(
                          alpha: 0.2,
                        ), // Updated for Flutter 2026 standards
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Text(
                        "STAFF- ${widget.currentUserName.toUpperCase()}",
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 12,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),

            // 2. PRIMARY NAVIGATION (Top Section)
            ListTile(
              leading: const Icon(Icons.shopping_basket, color: Colors.orange),
              title: const Text("Checkout Counter"),
              onTap: () => Navigator.pop(context), // Fixed: use onTap
            ),
            if (isAdmin)
              ListTile(
                leading: const Icon(
                  Icons.analytics_outlined,
                  color: Colors.orange,
                ),
                title: const Text("Reports & Analytics"),
                onTap: () {
                  // Fixed: use onTap
                  Navigator.pop(context);
                  Navigator.push(
                    context,
                    MaterialPageRoute(builder: (c) => const AnalyticsScreen()),
                  );
                },
              ),
            if (isAdmin)
              ListTile(
                leading: const Icon(
                  Icons.inventory_2_outlined,
                  color: Colors.orange,
                ),
                title: const Text("Menu Management"),
                onTap: () async {
                  // Fixed: use onTap
                  Navigator.pop(context);
                  await Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (c) => const MenuManagementScreen(),
                    ),
                  );
                  if (mounted) setState(() {});
                },
              ),

            const Spacer(),

            const Divider(),
            const Padding(
              padding: EdgeInsets.only(left: 16, top: 10, bottom: 5),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  "SYSTEM MANAGEMENT",
                  style: TextStyle(
                    color: Colors.grey,
                    fontWeight: FontWeight.bold,
                    fontSize: 11,
                  ),
                ),
              ),
            ),

            // 3. LOWER BUTTONS
            ListTile(
              leading: const Icon(Icons.history, color: Colors.blue),
              title: const Text("Sales History"),
              onTap: () {
                // Fixed: use onTap
                Navigator.pop(context);
                Navigator.push(
                  context,
                  MaterialPageRoute(builder: (c) => const SalesHistoryScreen()),
                );
              },
            ),
            if (isAdmin)
              ListTile(
                leading: const Icon(Icons.people_outline, color: Colors.green),
                title: const Text("Staff Management"),
                onTap: () {
                  // Fixed: use onTap
                  Navigator.pop(context);
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (c) => const StaffManagementScreen(),
                    ),
                  );
                },
              ),
            ListTile(
              leading: Icon(
                Icons.sync,
                color: _isSyncing ? Colors.grey : Colors.orange,
              ),
              title: Text(_isSyncing ? "Syncing..." : "Refresh Cloud Data"),
              onTap: _isSyncing
                  ? null
                  : () {
                      // Fixed: use onTap
                      Navigator.pop(context);
                      _checkAndSyncInventory();
                    },
            ),
            ListTile(
              leading: const Icon(Icons.logout, color: Colors.red),
              title: const Text("Logout"),
              onTap: () async {
                // Fixed: use onTap
                await DatabaseHelper.logoutCurrentUser();
                if (!context.mounted) {
                  return;
                }
                Navigator.pushAndRemoveUntil(
                  context,
                  MaterialPageRoute(builder: (c) => const LoginScreen()),
                  (route) => false,
                );
              },
            ),
            const SizedBox(height: 150),
          ],
        ),
      ),

      body: SafeArea(
        child: _isSyncing
            ? const Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    CircularProgressIndicator(color: Colors.orange),
                    SizedBox(height: 10),
                    Text("Syncing Menu..."),
                  ],
                ),
              )
            : Column(
                children: [
                  Container(
                    height: 60,
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: ListView(
                      scrollDirection: Axis.horizontal,
                      children: ["Cooked", "Raw Meat", "Roasted", "Drinks"]
                          .map(
                            (c) => Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 4,
                              ),
                              child: ChoiceChip(
                                label: Text(c),
                                selected: selectedCat == c,
                                onSelected: (s) =>
                                    setState(() => selectedCat = c),
                              ),
                            ),
                          )
                          .toList(),
                    ),
                  ),

                  Expanded(
                    child: FutureBuilder<List<Map<String, dynamic>>>(
                      future: DatabaseHelper.getProducts(),
                      builder: (context, snap) {
                        if (!snap.hasData)
                          return const Center(
                            child: CircularProgressIndicator(),
                          );
                        final items = snap.data!
                            .where((i) => i['category'] == selectedCat)
                            .toList();

                        if (items.isEmpty)
                          return Center(
                            child: Text("No items in $selectedCat"),
                          );

                        return ListView.builder(
                          itemCount: items.length,
                          itemBuilder: (c, i) {
                            final itm = items[i];
                            double stock = (itm['stock'] ?? 0.0).toDouble();
                            bool isTracked = itm['category'] != "Cooked";
                            bool outOfStock = isTracked && stock <= 0;

                            return ListTile(
                              title: Text(
                                itm['name'],
                                style: const TextStyle(
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                              subtitle: Text(
                                "KSh ${itm['price']} ${isTracked ? '• Stock: $stock' : ''}",
                              ),
                              trailing: ElevatedButton(
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: outOfStock
                                      ? Colors.grey
                                      : Colors.orange.shade50,
                                  foregroundColor: outOfStock
                                      ? Colors.white
                                      : Colors.orange,
                                ),
                                onPressed: outOfStock
                                    ? null
                                    : () => _addToCart(itm, stock, isTracked),
                                child: Text(outOfStock ? "OUT" : "ADD"),
                              ),
                            );
                          },
                        );
                      },
                    ),
                  ),
                  if (cart.isNotEmpty) _footer(),
                ],
              ),
      ),
    );
  }

  void _addToCart(Map<String, dynamic> item, double stock, bool isTracked) {
    TextEditingController q = TextEditingController(text: "1");
    showDialog(
      context: context,
      builder: (c) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15)),
        title: Text("Add ${item['name']}"),
        content: TextField(
          controller: q,
          autofocus: true,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: InputDecoration(
            labelText: "Quantity (${item['unit']})",
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c),
            child: const Text("Cancel"),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.orange),
            onPressed: () {
              double val = double.tryParse(q.text) ?? 1.0;
              if (isTracked && val > stock) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text("Not enough stock!")),
                );
              } else {
                setState(
                  () => cart.add({
                    "name": item['name'],
                    "price": (item['price'] as double) * val,
                    "qty": val,
                    "unit": item['unit'],
                    "category": item['category'],
                  }),
                );
                Navigator.pop(c);
              }
            },
            child: const Text("Confirm", style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
  }

  Widget _footer() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        boxShadow: [const BoxShadow(color: Colors.black12, blurRadius: 10)],
        borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                "${cart.length} Items Selected",
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
              TextButton(
                onPressed: () => setState(() => cart.clear()),
                child: const Text(
                  "Clear All",
                  style: TextStyle(color: Colors.red),
                ),
              ),
            ],
          ),
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 150),
            child: ListView.separated(
              shrinkWrap: true,
              itemCount: cart.length,
              separatorBuilder: (context, index) => const Divider(height: 1),
              itemBuilder: (context, index) {
                final item = cart[index];
                return ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  title: Text("${item['name']} (x${item['qty']})"),
                  subtitle: Text("KSh ${item['price'].toStringAsFixed(2)}"),
                  trailing: IconButton(
                    icon: const Icon(
                      Icons.remove_circle_outline,
                      color: Colors.red,
                      size: 20,
                    ),
                    onPressed: () => _removeFromCart(index),
                  ),
                );
              },
            ),
          ),
          const Divider(thickness: 1.5),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text("Total Payable"),
                  Text(
                    "KSh ${total.toStringAsFixed(2)}",
                    style: const TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.bold,
                      color: Colors.orange,
                    ),
                  ),
                ],
              ),
              ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.orange,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 30,
                    vertical: 15,
                  ),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
                onPressed: () async {
                  String newId = await _generateSequentialId();
                  if (!mounted) {
                    return;
                  }
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (context) => PaymentScreen(
                        salesId: newId,
                        cart: List.from(cart),
                        total: total,
                        currentUserName: widget.currentUserName,
                        onComplete: () => setState(() => cart.clear()),
                      ),
                    ),
                  );
                },
                child: const Text(
                  "CHECKOUT",
                  style: TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// --- 4. SALES HISTORY SCREEN (Account-Aware & Cloud Sync Enabled) ---
class SalesHistoryScreen extends StatefulWidget {
  const SalesHistoryScreen({super.key});

  @override
  State<SalesHistoryScreen> createState() => _SalesHistoryScreenState();
}

class _SalesHistoryScreenState extends State<SalesHistoryScreen> {
  DateTimeRange _selectedRange = DateTimeRange(
    start: DateTime.now(),
    end: DateTime.now(),
  );

  bool _isSearching = false;
  bool _isSyncing = false; // Track sync state
  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = "";

  String _format(DateTime d) => DateFormat('yyyy-MM-dd').format(d);

  @override
  void initState() {
    super.initState();
    // ✅ AUTO-SYNC: Trigger pull when screen opens to ensure cloud data is visible locally
    _handleCloudSync();
  }

  // ✅ SYNC LOGIC: Triggers the DatabaseHelper to pull cloud data
  Future<void> _handleCloudSync() async {
    setState(() => _isSyncing = true);
    try {
      // This method (from Step A) downloads Firestore data to SQLite
      await DatabaseHelper.pullCloudSales();

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text("Cloud records synchronized"),
            backgroundColor: Colors.green,
            duration: Duration(seconds: 1),
          ),
        );
      }
    } catch (e) {
      debugPrint("Sync Error: $e");
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text("Sync failed: $e"),
            backgroundColor: Colors.red,
          ),
        );
      }
    } finally {
      // Turning off _isSyncing will cause the FutureBuilder to rebuild and show new data
      if (mounted) setState(() => _isSyncing = false);
    }
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final currentBizId = DatabaseHelper.currentBusinessId;

    return Scaffold(
      appBar: AppBar(
        title: _isSearching
            ? TextField(
                controller: _searchController,
                autofocus: true,
                decoration: const InputDecoration(
                  hintText: "Search ID, M-Pesa, or Staff...",
                  border: InputBorder.none,
                  hintStyle: TextStyle(color: Colors.white70),
                ),
                style: const TextStyle(color: Colors.white, fontSize: 18),
                onChanged: (val) =>
                    setState(() => _searchQuery = val.toUpperCase()),
              )
            : const Text("Sales History"),
        backgroundColor: Colors.orange,
        foregroundColor: Colors.white,
        actions: [
          // ✅ REFRESH BUTTON: Visual feedback while syncing
          _isSyncing
              ? const Center(
                  child: Padding(
                    padding: EdgeInsets.all(12),
                    child: SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                        color: Colors.white,
                        strokeWidth: 2,
                      ),
                    ),
                  ),
                )
              : IconButton(
                  icon: const Icon(Icons.sync),
                  onPressed: _handleCloudSync,
                  tooltip: "Sync Cloud Records",
                ),
          IconButton(
            icon: Icon(_isSearching ? Icons.close : Icons.search),
            onPressed: () {
              setState(() {
                _isSearching = !_isSearching;
                if (!_isSearching) _searchQuery = "";
                _searchController.clear();
              });
            },
          ),
          IconButton(
            icon: const Icon(Icons.date_range),
            onPressed: () async {
              final DateTimeRange? picked = await showDateRangePicker(
                context: context,
                initialDateRange: _selectedRange,
                firstDate: DateTime(2023),
                lastDate: DateTime.now().add(const Duration(days: 1)),
                builder: (context, child) {
                  return Theme(
                    data: Theme.of(context).copyWith(
                      colorScheme: const ColorScheme.light(
                        primary: Colors.orange,
                      ),
                    ),
                    child: child!,
                  );
                },
              );
              if (picked != null) {
                setState(() => _selectedRange = picked);
              }
            },
          ),
        ],
      ),
      body: Column(
        children: [
          // Status Bar
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 20),
            color: Colors.orange.shade50,
            child: Text(
              _isSearching
                  ? "Results for: $_searchQuery"
                  : "Shop: $currentBizId | ${_format(_selectedRange.start)} to ${_format(_selectedRange.end)}",
              style: const TextStyle(
                fontWeight: FontWeight.bold,
                color: Colors.orange,
              ),
              textAlign: TextAlign.center,
            ),
          ),

          Expanded(
            child: FutureBuilder<List<Map<String, dynamic>>>(
              // This refreshes whenever _isSyncing or _selectedRange changes
              future: DatabaseHelper.database.then((db) {
                if (_isSearching && _searchQuery.isNotEmpty) {
                  return db.query(
                    'sales',
                    where:
                        'business_id = ? AND (ref LIKE ? OR method LIKE ? OR sold_by LIKE ?)',
                    whereArgs: [
                      currentBizId,
                      '%$_searchQuery%',
                      '%$_searchQuery%',
                      '%$_searchQuery%',
                    ],
                    orderBy: 'id DESC',
                  );
                } else {
                  return db.query(
                    'sales',
                    where: 'business_id = ? AND search_date BETWEEN ? AND ?',
                    whereArgs: [
                      currentBizId,
                      _format(_selectedRange.start),
                      _format(_selectedRange.end),
                    ],
                    orderBy: 'id DESC',
                  );
                }
              }),
              builder: (context, snapshot) {
                // Show loader only on initial load, not during background syncs
                if (snapshot.connectionState == ConnectionState.waiting &&
                    !_isSyncing) {
                  return const Center(child: CircularProgressIndicator());
                }

                final sales = snapshot.data ?? [];

                if (sales.isEmpty) {
                  return Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          Icons.history_toggle_off,
                          size: 64,
                          color: Colors.grey.shade300,
                        ),
                        const SizedBox(height: 16),
                        const Text("No records found locally."),
                        const SizedBox(height: 8),
                        ElevatedButton.icon(
                          onPressed: _handleCloudSync,
                          icon: const Icon(Icons.cloud_download),
                          label: const Text("Force Cloud Pull"),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.orange,
                            foregroundColor: Colors.white,
                          ),
                        ),
                      ],
                    ),
                  );
                }

                double grandTotal = sales.fold(
                  0.0,
                  (totalRevenue, item) => totalRevenue + (item['total'] ?? 0.0),
                );

                return Column(
                  children: [
                    Expanded(
                      child: ListView.builder(
                        itemCount: sales.length,
                        itemBuilder: (context, index) {
                          final sale = sales[index];
                          String displayId =
                              (sale['ref'] == null || sale['ref'].isEmpty)
                              ? "SALE-${sale['id']}"
                              : sale['ref'];
                          String soldBy = sale['sold_by'] ?? "System";

                          return Card(
                            margin: const EdgeInsets.symmetric(
                              horizontal: 10,
                              vertical: 5,
                            ),
                            elevation: 0,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(10),
                              side: BorderSide(color: Colors.grey.shade200),
                            ),
                            child: ExpansionTile(
                              leading: CircleAvatar(
                                backgroundColor: Colors.orange.shade50,
                                child: Icon(
                                  sale['method'].toString().contains("M-Pesa")
                                      ? Icons.phone_android
                                      : Icons.payments,
                                  color: Colors.orange,
                                  size: 20,
                                ),
                              ),
                              title: Text(
                                displayId,
                                style: const TextStyle(
                                  fontWeight: FontWeight.bold,
                                  fontSize: 14,
                                ),
                              ),
                              subtitle: Text(
                                "${sale['date']}\nServed by: $soldBy"
                                    .toUpperCase(),
                              ),
                              trailing: Text(
                                "KSh ${sale['total'].toStringAsFixed(2)}",
                                style: const TextStyle(
                                  fontWeight: FontWeight.bold,
                                  color: Colors.green,
                                  fontSize: 15,
                                ),
                              ),
                              children: [
                                Container(
                                  width: double.infinity,
                                  color: Colors.grey.shade50,
                                  padding: const EdgeInsets.all(16),
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      const Text(
                                        "SALE DETAILS",
                                        style: TextStyle(
                                          fontSize: 11,
                                          fontWeight: FontWeight.bold,
                                          color: Colors.grey,
                                        ),
                                      ),
                                      const SizedBox(height: 8),
                                      FutureBuilder<List<Map<String, dynamic>>>(
                                        future: DatabaseHelper.getSaleItems(
                                          sale['id'],
                                        ),
                                        builder: (context, itemSnap) {
                                          if (!itemSnap.hasData)
                                            return const LinearProgressIndicator();
                                          return Column(
                                            children: itemSnap.data!
                                                .map(
                                                  (item) => Padding(
                                                    padding:
                                                        const EdgeInsets.symmetric(
                                                          vertical: 4,
                                                        ),
                                                    child: Row(
                                                      mainAxisAlignment:
                                                          MainAxisAlignment
                                                              .spaceBetween,
                                                      children: [
                                                        Text(
                                                          "${item['qty']} x ${item['name']}",
                                                          style:
                                                              const TextStyle(
                                                                fontSize: 13,
                                                              ),
                                                        ),
                                                        Text(
                                                          "KSh ${(item['price'] * item['qty']).toStringAsFixed(2)}",
                                                          style:
                                                              const TextStyle(
                                                                fontSize: 13,
                                                                fontWeight:
                                                                    FontWeight
                                                                        .bold,
                                                              ),
                                                        ),
                                                      ],
                                                    ),
                                                  ),
                                                )
                                                .toList(),
                                          );
                                        },
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          );
                        },
                      ),
                    ),
                    // REVENUE FOOTER
                    SafeArea(
                      top: false,
                      child: Container(
                        padding: const EdgeInsets.fromLTRB(20, 20, 20, 20),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withValues(alpha: 0.05),
                              blurRadius: 10,
                              offset: const Offset(0, -5),
                            ),
                          ],
                          border: const Border(
                            top: BorderSide(color: Colors.orange, width: 3),
                          ),
                        ),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            const Text(
                              "Total for Period:",
                              style: TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            Text(
                              "KSh ${grandTotal.toStringAsFixed(2)}",
                              style: const TextStyle(
                                fontSize: 20,
                                fontWeight: FontWeight.w900,
                                color: Colors.orange,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

// --- 5. PAYMENT SCREEN (Finalized with Cloud Sync) ---
class PaymentScreen extends StatefulWidget {
  final double total;
  final List<Map<String, dynamic>> cart;
  final VoidCallback onComplete;
  final String salesId;
  final String currentUserName;

  const PaymentScreen({
    super.key,
    required this.total,
    required this.cart,
    required this.onComplete,
    required this.salesId,
    required this.currentUserName,
  });

  @override
  State<PaymentScreen> createState() => _PaymentScreenState();
}

class _PaymentScreenState extends State<PaymentScreen> {
  String method = "Cash";
  double amountReceived = 0;
  final TextEditingController _mpesaController = TextEditingController();
  bool _isProcessing = false;
  String _businessName = "";

  @override
  void initState() {
    super.initState();
    _loadBusinessName();
    _mpesaController.addListener(() {
      final String text = _mpesaController.text.toUpperCase();
      if (_mpesaController.text != text) {
        _mpesaController.value = _mpesaController.value.copyWith(
          text: text,
          selection: TextSelection.collapsed(offset: text.length),
        );
      }
      setState(() {});
    });
  }

  Future<void> _loadBusinessName() async {
    final bizId = DatabaseHelper.currentBusinessId;
    if (bizId == null || bizId.isEmpty) return;

    try {
      final doc = await FirebaseFirestore.instance
          .collection('businesses')
          .doc(bizId)
          .get();

      if (!mounted) {
        return;
      }
      setState(() {
        _businessName =
            (doc.data()?['business_name']?.toString().trim().isNotEmpty ??
                false)
            ? doc.data()!['business_name'].toString()
            : bizId;
      });
    } catch (e) {
      debugPrint("Failed to load business name: $e");
      if (!mounted) {
        return;
      }
      setState(() {
        _businessName = bizId;
      });
    }
  }

  bool _isValidMpesa(String code) => RegExp(r'^[A-Z0-9]{10}$').hasMatch(code);
  @override
  void dispose() {
    _mpesaController.dispose();
    super.dispose();
  }

  Future<void> _processCompletion(String mpesaCode, double change) async {
    if (_isProcessing) return; // Prevent double-taps

    setState(() => _isProcessing = true);

    String paymentDetail = method == "Cash"
        ? "Cash (Rec: $amountReceived)"
        : "M-Pesa ($mpesaCode)";

    final navigator = Navigator.of(context);

    // Show a loading indicator while syncing to cloud
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) =>
          const Center(child: CircularProgressIndicator(color: Colors.orange)),
    );

    try {
      // 1. Save to Local SQLite (Atomic operation)
      int localSaleId = await DatabaseHelper.insertSale(
        {
          "date": DateFormat('yyyy-MM-dd HH:mm').format(DateTime.now()),
          "total": widget.total,
          "method": paymentDetail,
          "ref": widget.salesId,
        },
        widget.cart,
        widget.currentUserName,
      );

      // 2. TRIGGER CLOUD SYNC: Mirror the sale to the specific Business Account
      try {
        // This ensures the owner can see the sale on their dashboard immediately
        await DatabaseHelper.syncSaleToCloud(localSaleId);
      } catch (cloudError) {
        // We don't block the UI if sync fails (it will retry next time app opens)
        debugPrint("Cloud sync deferred: $cloudError");
      }

      // 3. Cleanup local cart
      widget.onComplete();

      if (!mounted) {
        return;
      }
      navigator.pop(); // Remove loading spinner

      // 4. Navigate to Receipt
      navigator.pushReplacement(
        MaterialPageRoute(
          builder: (c) => ReceiptScreen(
            total: widget.total,
            received: amountReceived,
            change: change,
            method: method,
            mpesaRef: mpesaCode,
            salesId: widget.salesId,
            sellerName: widget.currentUserName,
            cart: widget.cart,
          ),
        ),
      );
    } catch (e) {
      if (mounted) {
        navigator.pop(); // Remove spinner
        setState(() => _isProcessing = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("Error: $e"), backgroundColor: Colors.red),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    double change = amountReceived - widget.total;
    String mpesaCode = _mpesaController.text;
    bool canFinish =
        (method == "M-Pesa" && _isValidMpesa(mpesaCode)) ||
        (method == "Cash" && amountReceived >= widget.total);

    return Scaffold(
      appBar: AppBar(
        title: const Text("Finalize Payment"),
        backgroundColor: Colors.orange,
        foregroundColor: Colors.white,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(25),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      "Business Name",
                      style: TextStyle(
                        fontSize: 12,
                        color: Colors.orange,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    Text(
                      _businessName.isEmpty
                          ? (DatabaseHelper.currentBusinessId ?? "DEMO")
                          : _businessName,
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 10),
                    const Text(
                      "Order Reference",
                      style: TextStyle(fontSize: 12, color: Colors.grey),
                    ),
                    Text(
                      widget.salesId,
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    const Text(
                      "Staff Member",
                      style: TextStyle(fontSize: 12, color: Colors.grey),
                    ),
                    Text(
                      widget.currentUserName.toUpperCase(),
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                ),
              ],
            ),
            const Divider(height: 40),
            const Text("Amount Due:", style: TextStyle(fontSize: 16)),
            Text(
              "KSh ${widget.total.toStringAsFixed(2)}",
              style: const TextStyle(
                fontSize: 45,
                fontWeight: FontWeight.bold,
                color: Colors.green,
              ),
            ),
            const SizedBox(height: 30),

            const Text(
              "Payment Method",
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                ChoiceChip(
                  label: const Text("Cash"),
                  selected: method == "Cash",
                  onSelected: (s) => setState(() => method = "Cash"),
                  selectedColor: Colors.orange.shade100,
                ),
                const SizedBox(width: 12),
                ChoiceChip(
                  label: const Text("M-Pesa"),
                  selected: method == "M-Pesa",
                  onSelected: (s) => setState(() => method = "M-Pesa"),
                  selectedColor: Colors.orange.shade100,
                ),
              ],
            ),
            const SizedBox(height: 30),

            if (method == "Cash") ...[
              TextField(
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                autofocus: true,
                style: const TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.bold,
                ),
                decoration: const InputDecoration(
                  labelText: "Cash Received",
                  border: OutlineInputBorder(),
                  prefixText: "KSh ",
                  floatingLabelBehavior: FloatingLabelBehavior.always,
                ),
                onChanged: (v) =>
                    setState(() => amountReceived = double.tryParse(v) ?? 0),
              ),
              const SizedBox(height: 15),
              if (amountReceived > 0)
                Container(
                  padding: const EdgeInsets.all(15),
                  width: double.infinity,
                  decoration: BoxDecoration(
                    color: change < 0
                        ? Colors.red.shade50
                        : Colors.blue.shade50,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(
                    change < 0
                        ? "Short: KSh ${(change * -1).toStringAsFixed(2)}"
                        : "Change: KSh ${change.toStringAsFixed(2)}",
                    style: TextStyle(
                      fontSize: 22,
                      color: change < 0 ? Colors.red : Colors.blue.shade700,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
            ],

            if (method == "M-Pesa")
              TextField(
                controller: _mpesaController,
                maxLength: 10,
                style: const TextStyle(
                  fontSize: 20,
                  letterSpacing: 2,
                  fontWeight: FontWeight.bold,
                ),
                decoration: InputDecoration(
                  labelText: "M-Pesa Ref Code",
                  helperText: "Format: ABC123DEF4",
                  border: const OutlineInputBorder(),
                  counterText: "${mpesaCode.length}/10",
                  errorText: (mpesaCode.isNotEmpty && !_isValidMpesa(mpesaCode))
                      ? "Invalid Code"
                      : null,
                ),
              ),
            const SizedBox(height: 40),

            ElevatedButton(
              style: ElevatedButton.styleFrom(
                minimumSize: const Size(double.infinity, 70),
                backgroundColor: canFinish
                    ? Colors.orange
                    : Colors.grey.shade400,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(15),
                ),
              ),
              onPressed: !canFinish || _isProcessing
                  ? null
                  : () => _processCompletion(mpesaCode, change),
              child: _isProcessing
                  ? const CircularProgressIndicator(color: Colors.white)
                  : const Text(
                      "COMPLETE SALE",
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

// --- 6. RECEIPT SCREEN ---
class ReceiptScreen extends StatefulWidget {
  final double total, received, change;
  final String method, mpesaRef;
  final String salesId;
  final String sellerName;
  final List<Map<String, dynamic>> cart;

  const ReceiptScreen({
    super.key,
    required this.total,
    required this.received,
    required this.change,
    required this.method,
    required this.mpesaRef,
    required this.salesId,
    required this.sellerName,
    required this.cart,
  });

  @override
  State<ReceiptScreen> createState() => _ReceiptScreenState();
}

class _ReceiptScreenState extends State<ReceiptScreen> {
  String _businessName = "";
  bool _isPrinting = false;
  bool _isDownloading = false;

  @override
  void initState() {
    super.initState();
    _loadBusinessName();
  }

  Future<void> _loadBusinessName() async {
    final bizId = DatabaseHelper.currentBusinessId;
    if (bizId == null || bizId.isEmpty) {
      return;
    }

    try {
      final doc = await FirebaseFirestore.instance
          .collection('businesses')
          .doc(bizId)
          .get();

      if (!mounted) {
        return;
      }
      setState(() {
        _businessName =
            (doc.data()?['business_name']?.toString().trim().isNotEmpty ??
                false)
            ? doc.data()!['business_name'].toString()
            : bizId;
      });
    } catch (e) {
      debugPrint("Failed to load business name for receipt: $e");
      if (!mounted) {
        return;
      }
      setState(() {
        _businessName = bizId;
      });
    }
  }

  String _getBusinessLabel() {
    return _businessName.isEmpty
        ? (DatabaseHelper.currentBusinessId ?? 'Business')
        : _businessName;
  }

  String _formatQty(double qty) {
    return qty % 1 == 0 ? qty.toInt().toString() : qty.toStringAsFixed(1);
  }

  List<Map<String, dynamic>> _normalizedCartItems() {
    return widget.cart.map((item) {
      final qty = (item['qty'] is num)
          ? (item['qty'] as num).toDouble()
          : double.tryParse(item['qty'].toString()) ?? 1.0;
      final lineTotal = (item['price'] is num)
          ? (item['price'] as num).toDouble()
          : double.tryParse(item['price'].toString()) ?? 0.0;
      final unitPrice = qty > 0 ? lineTotal / qty : lineTotal;

      return {
        'name': item['name'].toString(),
        'qty': qty,
        'qtyText': _formatQty(qty),
        'unitPrice': unitPrice,
        'lineTotal': lineTotal,
      };
    }).toList();
  }

  Future<Uint8List> _buildReceiptPdfBytes() async {
    final businessLabel = _getBusinessLabel();
    final items = _normalizedCartItems();
    final pdf = pw.Document();

    final estimatedHeightMm = 120 + (items.length * 10);
    final pageFormat = PdfPageFormat(
      80 * PdfPageFormat.mm,
      estimatedHeightMm * PdfPageFormat.mm,
      marginLeft: 6 * PdfPageFormat.mm,
      marginRight: 6 * PdfPageFormat.mm,
      marginTop: 8 * PdfPageFormat.mm,
      marginBottom: 8 * PdfPageFormat.mm,
    );

    pw.Widget divider() => pw.Container(
      margin: const pw.EdgeInsets.symmetric(vertical: 8),
      height: 0.7,
      color: PdfColors.grey400,
    );

    pw.Widget infoLabel(String text) => pw.Text(
      text,
      style: pw.TextStyle(fontSize: 9, color: PdfColors.grey700),
    );

    pw.Widget infoValue(
      String text, {
      pw.TextAlign align = pw.TextAlign.left,
    }) => pw.Text(
      text,
      textAlign: align,
      style: pw.TextStyle(fontSize: 10, fontWeight: pw.FontWeight.bold),
    );

    pdf.addPage(
      pw.Page(
        pageFormat: pageFormat,
        build: (context) {
          return pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.stretch,
            children: [
              pw.Text(
                businessLabel.toUpperCase(),
                textAlign: pw.TextAlign.center,
                style: pw.TextStyle(
                  fontSize: 14,
                  fontWeight: pw.FontWeight.bold,
                  letterSpacing: 0.6,
                ),
              ),
              pw.SizedBox(height: 8),
              pw.Text(
                'RECEIPT',
                textAlign: pw.TextAlign.center,
                style: pw.TextStyle(
                  fontSize: 10,
                  color: PdfColors.grey700,
                  letterSpacing: 2,
                ),
              ),
              divider(),
              pw.Row(
                crossAxisAlignment: pw.CrossAxisAlignment.start,
                children: [
                  pw.Expanded(
                    child: pw.Column(
                      crossAxisAlignment: pw.CrossAxisAlignment.start,
                      children: [
                        infoLabel('Bill No:'),
                        pw.SizedBox(height: 2),
                        infoValue(widget.salesId),
                      ],
                    ),
                  ),
                  pw.SizedBox(width: 10),
                  pw.Column(
                    crossAxisAlignment: pw.CrossAxisAlignment.end,
                    children: [
                      infoLabel('Staff:'),
                      pw.SizedBox(height: 2),
                      infoValue(
                        widget.sellerName.toUpperCase(),
                        align: pw.TextAlign.right,
                      ),
                    ],
                  ),
                ],
              ),
              divider(),
              pw.Row(
                children: [
                  pw.SizedBox(
                    width: 22,
                    child: pw.Text(
                      'QTY',
                      style: pw.TextStyle(
                        fontSize: 8,
                        fontWeight: pw.FontWeight.bold,
                        color: PdfColors.grey700,
                      ),
                    ),
                  ),
                  pw.Expanded(
                    child: pw.Text(
                      'ITEM',
                      style: pw.TextStyle(
                        fontSize: 8,
                        fontWeight: pw.FontWeight.bold,
                        color: PdfColors.grey700,
                      ),
                    ),
                  ),
                  pw.SizedBox(
                    width: 38,
                    child: pw.Text(
                      'PRICE',
                      textAlign: pw.TextAlign.right,
                      style: pw.TextStyle(
                        fontSize: 8,
                        fontWeight: pw.FontWeight.bold,
                        color: PdfColors.grey700,
                      ),
                    ),
                  ),
                  pw.SizedBox(width: 8),
                  pw.SizedBox(
                    width: 38,
                    child: pw.Text(
                      'TOTAL',
                      textAlign: pw.TextAlign.right,
                      style: pw.TextStyle(
                        fontSize: 8,
                        fontWeight: pw.FontWeight.bold,
                        color: PdfColors.grey700,
                      ),
                    ),
                  ),
                ],
              ),
              pw.SizedBox(height: 6),
              pw.Container(height: 0.7, color: PdfColors.grey400),
              pw.SizedBox(height: 6),
              ...items.map(
                (item) => pw.Padding(
                  padding: const pw.EdgeInsets.symmetric(vertical: 4),
                  child: pw.Row(
                    crossAxisAlignment: pw.CrossAxisAlignment.start,
                    children: [
                      pw.SizedBox(
                        width: 22,
                        child: pw.Text(
                          item['qtyText'].toString(),
                          style: const pw.TextStyle(fontSize: 9),
                        ),
                      ),
                      pw.Expanded(
                        child: pw.Text(
                          item['name'].toString(),
                          style: const pw.TextStyle(fontSize: 9),
                        ),
                      ),
                      pw.SizedBox(
                        width: 38,
                        child: pw.Text(
                          (item['unitPrice'] as double).toStringAsFixed(2),
                          textAlign: pw.TextAlign.right,
                          style: const pw.TextStyle(fontSize: 9),
                        ),
                      ),
                      pw.SizedBox(width: 8),
                      pw.SizedBox(
                        width: 38,
                        child: pw.Text(
                          (item['lineTotal'] as double).toStringAsFixed(2),
                          textAlign: pw.TextAlign.right,
                          style: const pw.TextStyle(fontSize: 9),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              divider(),
              _pdfReceiptRow(
                'Subtotal',
                'KSh ${widget.total.toStringAsFixed(2)}',
              ),
              pw.SizedBox(height: 6),
              _pdfReceiptRow(
                'Payment (${widget.method})',
                widget.method == 'Cash'
                    ? 'KSh ${widget.received.toStringAsFixed(2)}'
                    : widget.mpesaRef,
              ),
              pw.SizedBox(height: 8),
              pw.Container(height: 0.7, color: PdfColors.grey400),
              pw.SizedBox(height: 8),
              _pdfReceiptRow(
                'TOTAL DUE',
                'KSh ${widget.total.toStringAsFixed(2)}',
                isBold: true,
                fontSize: 14,
              ),
              if (widget.method == 'Cash') ...[
                pw.SizedBox(height: 6),
                _pdfReceiptRow(
                  'CHANGE',
                  'KSh ${widget.change.toStringAsFixed(2)}',
                  isBold: true,
                  fontSize: 11,
                  valueColor: PdfColors.green700,
                ),
              ],
              pw.SizedBox(height: 16),
              pw.Text(
                DateFormat('MMM dd, yyyy  hh:mm a').format(DateTime.now()),
                textAlign: pw.TextAlign.center,
                style: pw.TextStyle(fontSize: 8, color: PdfColors.grey700),
              ),
              pw.SizedBox(height: 8),
              pw.Text(
                'Thank you for your business!',
                textAlign: pw.TextAlign.center,
                style: pw.TextStyle(
                  fontSize: 9,
                  color: PdfColors.grey700,
                  fontStyle: pw.FontStyle.italic,
                ),
              ),
            ],
          );
        },
      ),
    );

    return pdf.save();
  }

  pw.Widget _pdfReceiptRow(
    String label,
    String value, {
    bool isBold = false,
    double fontSize = 10,
    PdfColor? valueColor,
  }) {
    return pw.Row(
      mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        pw.Expanded(
          child: pw.Text(
            label,
            style: pw.TextStyle(
              fontSize: fontSize,
              fontWeight: isBold ? pw.FontWeight.bold : pw.FontWeight.normal,
              color: isBold ? PdfColors.black : PdfColors.grey700,
            ),
          ),
        ),
        pw.SizedBox(width: 12),
        pw.Text(
          value,
          textAlign: pw.TextAlign.right,
          style: pw.TextStyle(
            fontSize: fontSize,
            fontWeight: isBold ? pw.FontWeight.bold : pw.FontWeight.normal,
            color: valueColor ?? PdfColors.black,
          ),
        ),
      ],
    );
  }

  Future<Directory> _resolveReceiptSaveDirectory() async {
    if (Platform.isAndroid) {
      const androidDownloadsPath = '/storage/emulated/0/Download';
      final androidDownloadsDir = Directory(androidDownloadsPath);

      if (await androidDownloadsDir.exists()) {
        final receiptsDir = Directory(
          p.join(androidDownloadsDir.path, 'PayNPlateReceipts'),
        );
        if (!await receiptsDir.exists()) {
          await receiptsDir.create(recursive: true);
        }
        return receiptsDir;
      }
    }

    try {
      final homeDir =
          Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'];
      if (homeDir != null && homeDir.isNotEmpty) {
        final downloadsDir = Directory(
          p.join(homeDir, 'Downloads', 'PayNPlateReceipts'),
        );
        if (!await downloadsDir.exists()) {
          await downloadsDir.create(recursive: true);
        }
        return downloadsDir;
      }
    } catch (_) {}

    final dir = await getApplicationDocumentsDirectory();
    final receiptsDir = Directory(p.join(dir.path, 'receipts'));
    if (!await receiptsDir.exists()) {
      await receiptsDir.create(recursive: true);
    }
    return receiptsDir;
  }

  Future<File> _saveReceiptLocally() async {
    final receiptsDir = await _resolveReceiptSaveDirectory();
    final file = File(p.join(receiptsDir.path, '${widget.salesId}.pdf'));
    final pdfBytes = await _buildReceiptPdfBytes();
    await file.writeAsBytes(pdfBytes, flush: true);
    return file;
  }

  Future<void> _printReceipt() async {
    if (_isPrinting) {
      return;
    }

    setState(() => _isPrinting = true);

    try {
      final pdfBytes = await _buildReceiptPdfBytes();
      await Printing.layoutPdf(
        onLayout: (PdfPageFormat format) async => pdfBytes,
        name: 'Receipt ${widget.salesId}',
      );

      if (!mounted) {
        return;
      }

      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Print dialog opened.')));
    } catch (e) {
      if (!mounted) {
        return;
      }

      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Print failed: $e')));
    } finally {
      if (mounted) {
        setState(() => _isPrinting = false);
      }
    }
  }

  Future<void> _downloadReceipt() async {
    if (_isDownloading) {
      return;
    }

    setState(() => _isDownloading = true);

    try {
      final file = await _saveReceiptLocally();

      if (!mounted) {
        return;
      }

      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Receipt saved to: ${file.path}')));
    } catch (e) {
      if (!mounted) {
        return;
      }

      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Download failed: $e')));
    } finally {
      if (mounted) {
        setState(() => _isDownloading = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final businessLabel = _getBusinessLabel();

    return PopScope(
      canPop: false,
      child: Scaffold(
        backgroundColor: Colors.grey[100],
        body: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(25.0),
            child: Column(
              children: [
                const Icon(Icons.check_circle, size: 80, color: Colors.green),
                const SizedBox(height: 10),
                const Text(
                  "Sale Complete",
                  style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 25),
                Container(
                  width: double.infinity,
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(4),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.1),
                        blurRadius: 10,
                        offset: const Offset(0, 5),
                      ),
                    ],
                  ),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 20,
                      vertical: 22,
                    ),
                    child: Column(
                      children: [
                        Text(
                          businessLabel.toUpperCase(),
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.w700,
                            letterSpacing: 0.6,
                          ),
                        ),
                        const SizedBox(height: 12),
                        const Text(
                          "RECEIPT",
                          style: TextStyle(
                            letterSpacing: 3.5,
                            fontWeight: FontWeight.w600,
                            color: Colors.black54,
                            fontSize: 12,
                          ),
                        ),
                        const SizedBox(height: 14),
                        Container(height: 1, color: Colors.grey.shade300),
                        const SizedBox(height: 14),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  const Text(
                                    "Bill No:",
                                    style: TextStyle(
                                      fontSize: 13,
                                      color: Colors.black54,
                                    ),
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    widget.salesId,
                                    style: const TextStyle(
                                      fontSize: 14,
                                      fontWeight: FontWeight.w900,
                                      letterSpacing: 0.4,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            Column(
                              crossAxisAlignment: CrossAxisAlignment.end,
                              children: [
                                const Text(
                                  "Staff:",
                                  style: TextStyle(
                                    fontSize: 13,
                                    color: Colors.black54,
                                  ),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  widget.sellerName.toUpperCase(),
                                  style: const TextStyle(
                                    fontSize: 14,
                                    fontWeight: FontWeight.w900,
                                    letterSpacing: 0.4,
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                        const SizedBox(height: 16),
                        Container(height: 1, color: Colors.grey.shade300),
                        const SizedBox(height: 10),
                        Row(
                          children: const [
                            SizedBox(
                              width: 40,
                              child: Text(
                                'QTY',
                                style: TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.bold,
                                  color: Colors.black54,
                                ),
                              ),
                            ),
                            Expanded(
                              child: Text(
                                'ITEM',
                                style: TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.bold,
                                  color: Colors.black54,
                                ),
                              ),
                            ),
                            SizedBox(
                              width: 70,
                              child: Text(
                                'PRICE',
                                textAlign: TextAlign.right,
                                style: TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.bold,
                                  color: Colors.black54,
                                ),
                              ),
                            ),
                            SizedBox(width: 12),
                            SizedBox(
                              width: 70,
                              child: Text(
                                'TOTAL',
                                textAlign: TextAlign.right,
                                style: TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.bold,
                                  color: Colors.black54,
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        Container(height: 1, color: Colors.grey.shade300),
                        const SizedBox(height: 8),
                        ...widget.cart.map((item) {
                          final qty = (item['qty'] is num)
                              ? (item['qty'] as num).toDouble()
                              : double.tryParse(item['qty'].toString()) ?? 1.0;
                          final lineTotal = (item['price'] is num)
                              ? (item['price'] as num).toDouble()
                              : double.tryParse(item['price'].toString()) ??
                                    0.0;
                          final unitPrice = qty > 0
                              ? lineTotal / qty
                              : lineTotal;

                          return Padding(
                            padding: const EdgeInsets.symmetric(vertical: 6),
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                SizedBox(
                                  width: 40,
                                  child: Text(
                                    qty % 1 == 0
                                        ? qty.toInt().toString()
                                        : qty.toStringAsFixed(1),
                                    style: const TextStyle(fontSize: 13),
                                  ),
                                ),
                                Expanded(
                                  child: Text(
                                    item['name'].toString(),
                                    style: const TextStyle(fontSize: 13),
                                  ),
                                ),
                                SizedBox(
                                  width: 70,
                                  child: Text(
                                    unitPrice.toStringAsFixed(2),
                                    textAlign: TextAlign.right,
                                    style: const TextStyle(fontSize: 13),
                                  ),
                                ),
                                const SizedBox(width: 12),
                                SizedBox(
                                  width: 70,
                                  child: Text(
                                    lineTotal.toStringAsFixed(2),
                                    textAlign: TextAlign.right,
                                    style: const TextStyle(fontSize: 13),
                                  ),
                                ),
                              ],
                            ),
                          );
                        }),
                        const SizedBox(height: 8),
                        Container(height: 1, color: Colors.grey.shade300),
                        const SizedBox(height: 14),
                        _receiptRow(
                          "Subtotal",
                          "KSh ${widget.total.toStringAsFixed(2)}",
                        ),
                        const SizedBox(height: 8),
                        _receiptRow(
                          "Payment (${widget.method})",
                          widget.method == "Cash"
                              ? "KSh ${widget.received.toStringAsFixed(2)}"
                              : widget.mpesaRef,
                        ),
                        const SizedBox(height: 14),
                        Container(height: 1, color: Colors.grey.shade300),
                        const SizedBox(height: 14),
                        _receiptRow(
                          "TOTAL DUE",
                          "KSh ${widget.total.toStringAsFixed(2)}",
                          isBold: true,
                          size: 20,
                        ),
                        if (widget.method == "Cash")
                          _receiptRow(
                            "CHANGE",
                            "KSh ${widget.change.toStringAsFixed(2)}",
                            isBold: true,
                            valueColor: Colors.green,
                          ),
                        const SizedBox(height: 24),
                        Text(
                          DateFormat(
                            'MMM dd, yyyy  hh:mm a',
                          ).format(DateTime.now()),
                          style: const TextStyle(
                            fontSize: 11,
                            color: Colors.grey,
                          ),
                        ),
                        const SizedBox(height: 10),
                        const Text(
                          "Thank you for your business!",
                          style: TextStyle(
                            fontStyle: FontStyle.italic,
                            fontSize: 12,
                            color: Colors.grey,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 40),
                Row(
                  children: [
                    SizedBox(
                      width: 60,
                      height: 60,
                      child: IconButton.filled(
                        onPressed: _isDownloading ? null : _downloadReceipt,
                        icon: _isDownloading
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: Colors.white,
                                ),
                              )
                            : const Icon(Icons.download),
                        tooltip: 'Download Receipt',
                        style: IconButton.styleFrom(
                          backgroundColor: Colors.blueGrey,
                          foregroundColor: Colors.white,
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: SizedBox(
                        height: 60,
                        child: OutlinedButton.icon(
                          icon: _isPrinting
                              ? const SizedBox(
                                  width: 18,
                                  height: 18,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : const Icon(Icons.print),
                          label: Text(
                            _isPrinting ? "PROCESSING..." : "PRINT RECEIPT",
                            style: const TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: Colors.orange,
                            side: const BorderSide(
                              color: Colors.orange,
                              width: 1.5,
                            ),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                          ),
                          onPressed: _isPrinting ? null : _printReceipt,
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: SizedBox(
                        height: 60,
                        child: ElevatedButton.icon(
                          icon: const Icon(Icons.add_shopping_cart),
                          label: const Text(
                            "NEW ORDER",
                            style: TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.orange,
                            foregroundColor: Colors.white,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                          ),
                          onPressed: () => Navigator.pop(context),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _receiptRow(
    String label,
    String value, {
    bool isBold = false,
    Color? valueColor,
    double size = 15,
  }) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(
          label,
          style: TextStyle(
            color: isBold ? Colors.black : Colors.black54,
            fontSize: size,
            fontWeight: isBold ? FontWeight.bold : FontWeight.normal,
          ),
        ),
        Text(
          value,
          style: TextStyle(
            fontWeight: isBold ? FontWeight.bold : FontWeight.normal,
            fontSize: size,
            color: valueColor ?? Colors.black87,
          ),
        ),
      ],
    );
  }
}

// --- 7. ANALYTICS SCREEN (High-End Professional UI Upgrade) ---
class AnalyticsScreen extends StatefulWidget {
  const AnalyticsScreen({super.key});

  @override
  State<AnalyticsScreen> createState() => _AnalyticsScreenState();
}

class _AnalyticsScreenState extends State<AnalyticsScreen> {
  DateTimeRange _selectedRange = DateTimeRange(
    start: DateTime.now().subtract(const Duration(days: 6)),
    end: DateTime.now(),
  );

  bool _isSyncing = false;

  Future<void> _refreshCloudData() async {
    setState(() => _isSyncing = true);
    try {
      await DatabaseHelper.pullCloudProducts();
      await DatabaseHelper.pullCloudSales();

      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text("Account data synchronized successfully."),
          backgroundColor: Colors.green,
        ),
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text("Sync failed: $e"),
            backgroundColor: Colors.red,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _isSyncing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        backgroundColor: Colors.grey[50],
        appBar: AppBar(
          title: const Text(
            "Business Insights",
            style: TextStyle(fontWeight: FontWeight.bold),
          ),
          actions: [
            IconButton(
              icon: _isSyncing
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  : const Icon(Icons.sync),
              onPressed: _isSyncing ? null : _refreshCloudData,
            ),
            IconButton(
              icon: const Icon(Icons.calendar_month),
              onPressed: () async {
                final DateTimeRange? picked = await showDateRangePicker(
                  context: context,
                  initialDateRange: _selectedRange,
                  firstDate: DateTime(2023),
                  lastDate: DateTime.now(),
                );
                if (picked != null) {
                  setState(() => _selectedRange = picked);
                }
              },
            ),
          ],
          bottom: const TabBar(
            tabs: [
              Tab(text: "Daily Trends"),
              Tab(text: "Monthly Trends"),
            ],
            indicatorColor: Colors.white,
            labelStyle: TextStyle(fontWeight: FontWeight.bold),
          ),
          backgroundColor: Colors.orange,
          foregroundColor: Colors.white,
        ),
        body: TabBarView(
          children: [
            RevenueChart(type: "Daily", range: _selectedRange),
            RevenueChart(type: "Monthly", range: _selectedRange),
          ],
        ),
      ),
    );
  }
}

class RevenueChart extends StatelessWidget {
  final String type;
  final DateTimeRange range;

  const RevenueChart({super.key, required this.type, required this.range});

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<Map<String, dynamic>>>(
      future: DatabaseHelper.getRevenueSummary(type, range: range),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Center(
            child: CircularProgressIndicator(color: Colors.orange),
          );
        }

        if (!snapshot.hasData || snapshot.data!.isEmpty) {
          return const Center(child: Text("No data found for this period"));
        }

        final data = snapshot.data!;

        String headerDate = "Revenue Summary";
        try {
          DateTime firstDate = DateTime.parse(data.first['label']);
          headerDate = DateFormat('MMMM-yyyy').format(firstDate);
        } catch (_) {}

        double totalRevenue = data.fold(
          0.0,
          (acc, e) => acc + (e['revenue'] ?? 0.0),
        );
        double maxVal = data.fold(
          0.0,
          (max, e) => (e['revenue'] ?? 0.0) > max ? (e['revenue'] ?? 0.0) : max,
        );

        return SingleChildScrollView(
          child: Column(
            children: [
              // Dynamic Header Card
              Container(
                width: double.infinity,
                margin: const EdgeInsets.all(16),
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(15),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.05),
                      blurRadius: 10,
                    ),
                  ],
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      headerDate,
                      style: const TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 18,
                        color: Colors.blueGrey,
                      ),
                    ),
                    const SizedBox(height: 5),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text(
                          "Total Period Revenue",
                          style: TextStyle(color: Colors.grey),
                        ),
                        Text(
                          "KSh ${totalRevenue.toStringAsFixed(0)}",
                          style: const TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 20,
                            color: Colors.orange,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),

              // --- 📊 THE UPGRADED BAR CHART ---
              Container(
                height: 400,
                padding: const EdgeInsets.only(
                  right: 25,
                  left: 10,
                  top: 10,
                  bottom: 10,
                ),
                child: BarChart(
                  BarChartData(
                    alignment: BarChartAlignment.spaceAround,
                    maxY: (maxVal * 1.2).clamp(100.0, double.infinity),

                    // 1. Grid Customization: Dotted lines forming square boxes
                    gridData: FlGridData(
                      show: true,
                      drawVerticalLine: true,
                      horizontalInterval: maxVal > 0 ? maxVal / 5 : 1000,
                      verticalInterval: 1,
                      getDrawingHorizontalLine: (value) => FlLine(
                        color: Colors.grey.shade300,
                        strokeWidth: 1,
                        dashArray: [5, 5], // Dotted Effect
                      ),
                      getDrawingVerticalLine: (value) => FlLine(
                        color: Colors.grey.shade300,
                        strokeWidth: 1,
                        dashArray: [5, 5], // Dotted Effect
                      ),
                    ),

                    // 2. Axis Borders: Thick Lines on XY Axis
                    borderData: FlBorderData(
                      show: true,
                      border: const Border(
                        left: BorderSide(
                          color: Colors.black87,
                          width: 2,
                        ), // Thick Y Axis
                        bottom: BorderSide(
                          color: Colors.black87,
                          width: 2,
                        ), // Thick X Axis
                        top: BorderSide.none,
                        right: BorderSide.none,
                      ),
                    ),

                    titlesData: FlTitlesData(
                      leftTitles: AxisTitles(
                        sideTitles: SideTitles(
                          showTitles: true,
                          reservedSize: 45,
                          getTitlesWidget: (val, meta) {
                            String text = val >= 1000
                                ? '${(val / 1000).toStringAsFixed(1)}k'
                                : val.toInt().toString();
                            return Text(
                              text,
                              style: const TextStyle(
                                fontSize: 10,
                                color: Colors.blueGrey,
                              ),
                            );
                          },
                        ),
                      ),
                      bottomTitles: AxisTitles(
                        sideTitles: SideTitles(
                          showTitles: true,
                          getTitlesWidget: (val, meta) {
                            int idx = val.toInt();
                            if (idx >= 0 && idx < data.length) {
                              try {
                                DateTime dt = DateTime.parse(
                                  data[idx]['label'],
                                );
                                String formattedDate = type == "Monthly"
                                    ? DateFormat('MMM').format(dt)
                                    : DateFormat('E-dd').format(dt);
                                return Padding(
                                  padding: const EdgeInsets.only(top: 8.0),
                                  child: Text(
                                    formattedDate,
                                    style: const TextStyle(
                                      fontSize: 9,
                                      fontWeight: FontWeight.bold,
                                      color: Colors.black87,
                                    ),
                                  ),
                                );
                              } catch (e) {
                                return const SizedBox();
                              }
                            }
                            return const SizedBox();
                          },
                        ),
                      ),
                      rightTitles: const AxisTitles(
                        sideTitles: SideTitles(showTitles: false),
                      ),
                      topTitles: const AxisTitles(
                        sideTitles: SideTitles(showTitles: false),
                      ),
                    ),

                    barGroups: data.asMap().entries.map((e) {
                      return BarChartGroupData(
                        x: e.key,
                        barRods: [
                          BarChartRodData(
                            toY: (e.value['revenue'] ?? 0.0).toDouble(),
                            color: Colors.orange.shade600,
                            width: 20,
                            borderRadius: const BorderRadius.vertical(
                              top: Radius.circular(4),
                            ),
                            backDrawRodData: BackgroundBarChartRodData(
                              show: true,
                              toY: maxVal * 1.2,
                              color: Colors.orange.withValues(alpha: 0.05),
                            ),
                          ),
                        ],
                      );
                    }).toList(),
                  ),
                ),
              ),
              Padding(padding: const EdgeInsets.symmetric(vertical: 20)),
            ],
          ),
        );
      },
    );
  }
}

// --- 8. INVENTORY (Final Optimized & Error-Free Version) ---
class MenuManagementScreen extends StatefulWidget {
  const MenuManagementScreen({super.key});
  @override
  State<MenuManagementScreen> createState() => _MenuManagementScreenState();
}

class _MenuManagementScreenState extends State<MenuManagementScreen> {
  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = "";

  Color _getStockColor(Map<String, dynamic> item) {
    if (item['category'] == "Cooked") return Colors.green.shade700;
    double stock = (item['stock'] ?? 0).toDouble();
    if (stock <= 0) return Colors.red.shade700;
    if (stock <= 10) return Colors.orange.shade800;
    return Colors.green.shade700;
  }

  void _confirmDelete(int id, String name) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15)),
        title: Text("Delete $name?"),
        content: const Text(
          "This action cannot be undone. Remove this item from the menu?",
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text("CANCEL"),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () async {
              await DatabaseHelper.deleteProduct(id);
              // ✅ FIX: check mounted before using context after await
              if (!mounted) {
                return;
              }
              Navigator.pop(context);
              setState(() {});
            },
            child: const Text("DELETE", style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
  }

  void _edit(Map<String, dynamic>? itm) {
    final nC = TextEditingController(text: itm?['name'] ?? '');
    final pC = TextEditingController(text: itm?['price']?.toString() ?? '');
    final sC = TextEditingController(text: itm?['stock']?.toString() ?? '0');
    String currentUnit = itm?['unit'] ?? 'pcs';
    String cat = itm?['category'] ?? 'Cooked';

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Text(itm == null ? "New Menu Item" : "Edit Item"),
        content: SizedBox(
          width: MediaQuery.of(context).size.width * 0.9,
          child: SingleChildScrollView(
            child: StatefulBuilder(
              builder: (stContext, setModalState) => Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    controller: nC,
                    decoration: InputDecoration(
                      labelText: "Item Name",
                      prefixIcon: const Icon(Icons.restaurant),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                  ),
                  const SizedBox(height: 15),
                  DropdownButtonFormField<String>(
                    // ✅ FIX: replaced 'value' with 'initialValue' (Deprecation fix)
                    initialValue: cat,
                    decoration: InputDecoration(
                      labelText: "Category",
                      prefixIcon: const Icon(Icons.category),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    items: ["Cooked", "Raw Meat", "Roasted", "Drinks"]
                        .map((e) => DropdownMenuItem(value: e, child: Text(e)))
                        .toList(),
                    onChanged: (v) => setModalState(() => cat = v!),
                  ),
                  const SizedBox(height: 15),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: pC,
                          keyboardType: TextInputType.number,
                          decoration: InputDecoration(
                            labelText: "Price",
                            prefixIcon: const Icon(Icons.payments),
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      if (cat != "Cooked")
                        Expanded(
                          child: TextField(
                            controller: sC,
                            keyboardType: TextInputType.number,
                            decoration: InputDecoration(
                              labelText: "Stock",
                              prefixIcon: const Icon(Icons.inventory),
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(12),
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text("Cancel"),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.orange,
              foregroundColor: Colors.white,
            ),
            onPressed: () async {
              if (nC.text.isEmpty || pC.text.isEmpty) return;

              if (itm == null) {
                await DatabaseHelper.addProduct(
                  nC.text,
                  double.parse(pC.text),
                  cat,
                  currentUnit,
                  double.parse(sC.text),
                );
              } else {
                await DatabaseHelper.updateProduct(
                  itm['id'],
                  nC.text,
                  double.parse(pC.text),
                  cat,
                  currentUnit,
                  double.parse(sC.text),
                );
              }

              // ✅ FIX: check mounted before pop (use_build_context_synchronously fix)
              if (!mounted) {
                return;
              }
              Navigator.pop(context);
              setState(() {});
            },
            child: const Text("SAVE ITEM"),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.grey[50],
      appBar: AppBar(
        title: const Text(
          "Menu Management",
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
        backgroundColor: Colors.orange,
        foregroundColor: Colors.white,
      ),
      floatingActionButton: FloatingActionButton(
        backgroundColor: Colors.orange,
        onPressed: () => _edit(null),
        child: const Icon(Icons.add, color: Colors.white),
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(16.0),
            child: TextField(
              controller: _searchController,
              onChanged: (value) => setState(() => _searchQuery = value),
              decoration: InputDecoration(
                hintText: "Search items...",
                prefixIcon: const Icon(Icons.search, color: Colors.orange),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: const BorderSide(color: Colors.orange, width: 2),
                ),
              ),
            ),
          ),
          Expanded(
            child: FutureBuilder<List<Map<String, dynamic>>>(
              future: DatabaseHelper.getProducts(),
              builder: (c, s) {
                if (!s.hasData)
                  return const Center(
                    child: CircularProgressIndicator(color: Colors.orange),
                  );

                final filteredItems = s.data!.where((item) {
                  final name = item['name'].toString().toLowerCase();
                  return name.contains(_searchQuery.toLowerCase());
                }).toList();

                return ListView.builder(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  itemCount: filteredItems.length,
                  itemBuilder: (ctx, index) {
                    final item = filteredItems[index];
                    final Color stockColor = _getStockColor(item);

                    return Card(
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(15),
                      ),
                      elevation: 1,
                      child: ListTile(
                        title: Text(
                          item['name'],
                          style: const TextStyle(fontWeight: FontWeight.bold),
                        ),
                        subtitle: Text(
                          "KSh ${item['price']} • ${item['category']}",
                        ),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              item['category'] == "Cooked"
                                  ? "∞"
                                  : "Stock: ${item['stock']}",
                              style: TextStyle(
                                color: stockColor,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            IconButton(
                              icon: const Icon(Icons.edit, color: Colors.blue),
                              onPressed: () => _edit(item),
                            ),
                            IconButton(
                              icon: const Icon(Icons.delete, color: Colors.red),
                              onPressed: () =>
                                  _confirmDelete(item['id'], item['name']),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

// --- 9. STAFF MANAGEMENT SCREEN---
class StaffManagementScreen extends StatefulWidget {
  const StaffManagementScreen({super.key});

  @override
  State<StaffManagementScreen> createState() => _StaffManagementScreenState();
}

class _StaffManagementScreenState extends State<StaffManagementScreen> {
  void _addStaffMember() {
    final userC = TextEditingController();
    final passC = TextEditingController();
    final bizIdC = TextEditingController(); // For Bootstrap
    final bizNameC = TextEditingController(); // For Bootstrap
    String selectedRole = 'staff';
    bool isNewBusiness = false; // Toggle for Bootstrap Mode

    showDialog(
      context: context,
      barrierDismissible: false, // Prevent accidental close during sync
      builder: (ctx) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text(
            isNewBusiness ? "Register New Business" : "Create New User",
          ),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // 🚀 Toggle Button: Switch between adding staff to current biz vs Registering a new one
                SwitchListTile(
                  title: const Text(
                    "New Business?",
                    style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold),
                  ),
                  subtitle: const Text("Click to Register New Business"),
                  value: isNewBusiness,
                  onChanged: (val) => setDialogState(() => isNewBusiness = val),
                  activeThumbColor: Colors.orange,
                ),
                const Divider(),
                if (isNewBusiness) ...[
                  TextField(
                    controller: bizIdC,
                    decoration: const InputDecoration(
                      labelText: "Unique Business ID (e.g. BIZ_001)",
                      prefixIcon: Icon(Icons.fingerprint),
                    ),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: bizNameC,
                    decoration: const InputDecoration(
                      labelText: "Business Name (e.g. Mama Jane's)",
                      prefixIcon: Icon(Icons.business),
                    ),
                  ),
                  const SizedBox(height: 10),
                ],
                TextField(
                  controller: userC,
                  decoration: InputDecoration(
                    labelText: isNewBusiness ? "Admin Username" : "Username",
                    prefixIcon: const Icon(Icons.person_outline),
                  ),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: passC,
                  decoration: const InputDecoration(
                    labelText: "Initial Password",
                    prefixIcon: Icon(Icons.lock_outline),
                  ),
                  obscureText: true,
                ),
                if (!isNewBusiness) ...[
                  const SizedBox(height: 15),
                  DropdownButtonFormField<String>(
                    initialValue: selectedRole,
                    decoration: const InputDecoration(labelText: "User Role"),
                    items: const [
                      DropdownMenuItem(
                        value: 'staff',
                        child: Text("Regular Staff"),
                      ),
                      DropdownMenuItem(
                        value: 'admin',
                        child: Text("Administrator"),
                      ),
                    ],
                    onChanged: (val) =>
                        setDialogState(() => selectedRole = val!),
                  ),
                ],
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text("CANCEL"),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.orange,
                foregroundColor: Colors.white,
              ),
              onPressed: () async {
                final u = userC.text.trim();
                final p = passC.text.trim();

                if (u.isEmpty || p.isEmpty) return;

                try {
                  if (isNewBusiness) {
                    // 🚀 TRIGGER BOOTSTRAP: Creates the Root Business Acount
                    await DatabaseHelper.registerNewBusiness(
                      bizId: bizIdC.text.trim(),
                      bizName: bizNameC.text.trim(),
                      adminUser: u,
                      adminPass: p,
                    );
                  } else {
                    // Standard Staff Addition: Automatically pushes to Cloud Staff collection
                    await DatabaseHelper.addUser(u, p, selectedRole);
                  }

                  if (!ctx.mounted) return;
                  Navigator.pop(ctx);
                  if (mounted) {
                    setState(() {});
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text(
                          isNewBusiness
                              ? "Cloud Business Acount Live!"
                              : "Staff Broadcasted to Cloud!",
                        ),
                        backgroundColor: Colors.green,
                      ),
                    );
                  }
                } catch (e) {
                  if (mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text("Cloud Sync Error: $e"),
                        backgroundColor: Colors.red,
                      ),
                    );
                  }
                }
              },
              child: Text(isNewBusiness ? "BOOTSTRAP" : "SAVE & SYNC"),
            ),
          ],
        ),
      ),
    );
  }

  void _changePassword(String username) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text("Reset Password for $username"),
        content: const Text(
          "For the new Firebase Auth setup, direct password edits are disabled in-app. "
          "If this account has a real email, a reset email can be sent. "
          "If it uses the internal paynplate.app login email, reset it from your admin backend or Firebase Console.",
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text("CANCEL"),
          ),
          ElevatedButton(
            onPressed: () async {
              try {
                await DatabaseHelper.sendPasswordResetForUsername(username);
                if (!ctx.mounted) return;
                Navigator.pop(ctx);
                if (!mounted) {
                  return;
                }
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text("Password reset email sent.")),
                );
              } catch (e) {
                if (!ctx.mounted) return;
                Navigator.pop(ctx);
                if (!mounted) {
                  return;
                }
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text("Reset unavailable: $e"),
                    backgroundColor: Colors.red,
                  ),
                );
              }
            },
            child: const Text("SEND RESET"),
          ),
        ],
      ),
    );
  }

  void _confirmDelete(int id, String name, String role) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Icon(Icons.warning, color: Colors.red, size: 40),
        content: Text(
          "Remove '$name'? Access will be revoked immediately on all devices.",
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text("CANCEL"),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () async {
              final users = await DatabaseHelper.getAllUsers();
              final adminCount = users
                  .where((u) => u['role'] == 'admin')
                  .length;

              if (role == 'admin' && adminCount <= 1) {
                if (ctx.mounted) Navigator.pop(ctx);
                if (!mounted) {
                  return;
                }
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text("Cannot delete the last Admin!"),
                  ),
                );
                return;
              }

              // Deletes from both SQLite and Firestore
              await DatabaseHelper.deleteUser(id);

              if (!ctx.mounted) return;
              Navigator.pop(ctx);
              if (mounted) {
                setState(() {});
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text("Staff access removed from app data."),
                  ),
                );
              }
            },
            child: const Text("DELETE", style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.grey.shade100,
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text("Staff Management"),
            Text(
              "Business Acount: ${DatabaseHelper.currentBusinessId ?? 'None'}",
              style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.normal,
              ),
            ),
          ],
        ),
        backgroundColor: Colors.orange,
        foregroundColor: Colors.white,
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _addStaffMember,
        backgroundColor: Colors.orange,
        icon: const Icon(Icons.group_add, color: Colors.white),
        label: const Text(
          "Register User",
          style: TextStyle(color: Colors.white),
        ),
      ),
      body: FutureBuilder<List<Map<String, dynamic>>>(
        future: DatabaseHelper.getAllUsers(),
        builder: (context, snapshot) {
          if (!snapshot.hasData)
            return const Center(child: CircularProgressIndicator());
          final users = snapshot.data!;
          if (users.isEmpty)
            return const Center(child: Text("No users found."));

          return ListView.builder(
            padding: const EdgeInsets.all(12),
            itemCount: users.length,
            itemBuilder: (context, index) {
              final user = users[index];
              bool isAdminRole = user['role'] == 'admin';
              return Card(
                elevation: 0,
                margin: const EdgeInsets.only(bottom: 10),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(15),
                  side: BorderSide(color: Colors.grey.shade300),
                ),
                child: ListTile(
                  leading: CircleAvatar(
                    backgroundColor: isAdminRole
                        ? Colors.orange.shade100
                        : Colors.blueGrey.shade100,
                    child: Icon(
                      isAdminRole ? Icons.admin_panel_settings : Icons.person,
                      color: isAdminRole ? Colors.orange : Colors.blueGrey,
                    ),
                  ),
                  title: Text(
                    user['username'],
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                  subtitle: Text(
                    "Role: ${user['role'].toString().toUpperCase()}",
                  ),
                  trailing: PopupMenuButton<String>(
                    onSelected: (val) {
                      if (val == 'pass') _changePassword(user['username']);
                      if (val == 'del')
                        _confirmDelete(
                          user['id'],
                          user['username'],
                          user['role'],
                        );
                    },
                    itemBuilder: (context) => [
                      const PopupMenuItem(
                        value: 'pass',
                        child: Text("Change Password"),
                      ),
                      const PopupMenuItem(
                        value: 'del',
                        child: Text(
                          "Remove User",
                          style: TextStyle(color: Colors.red),
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }
}
