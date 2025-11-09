import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:go_router/go_router.dart';

/// Entry point of the application. This widget loads the environment, initializes
/// Supabase and then runs the app.
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Load environment variables from the `.env` file. In production you may
  // supply these at build time via --dart-define instead.
  await dotenv.load(fileName: '.env');

  // Initialize Supabase with the project URL and anon key. Make sure to
  // replace the placeholders in `.env` with your actual Supabase details.
  await Supabase.initialize(
    url: dotenv.env['SUPABASE_URL']!,
    anonKey: dotenv.env['SUPABASE_ANON_KEY']!,
  );
  debugPrint('***** Supabase init completed ${Supabase.instance.client}');
  runApp(const SaaSPosApp());
}

/// Root widget that configures routing and theming for the app.
class SaaSPosApp extends StatelessWidget {
  const SaaSPosApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp.router(
      title: 'F&B SaaS POS',
      routerConfig: _router,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepOrange),
      ),
    );
  }
}

/// Configure the app's routes using go_router. The two core routes are:
/// - `/`: the authentication gate
/// - `/home`: the post-auth home page
final GoRouter _router = GoRouter(
  routes: <GoRoute>[
    GoRoute(
      path: '/',
      builder: (context, state) => const AuthGate(),
    ),
    GoRoute(
      path: '/home',
      builder: (context, state) => const HomePage(),
    ),
  ],
);

/// Widget that presents login and sign‑up forms. Once authenticated it
/// calls a Supabase RPC to provision the organisation on first login.
class AuthGate extends StatefulWidget {
  const AuthGate({super.key});

  @override
  State<AuthGate> createState() => _AuthGateState();
}

class _AuthGateState extends State<AuthGate> {
  final SupabaseClient _client = Supabase.instance.client;
  final TextEditingController _email = TextEditingController();
  final TextEditingController _password = TextEditingController();
  bool _isLogin = true;
  bool _loading = false;

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    setState(() => _loading = true);
    try {
      if (_isLogin) {
        // Attempt to sign in with email and password
        await _client.auth.signInWithPassword(
          email: _email.text.trim(),
          password: _password.text,
        );
      } else {
        // Attempt to sign up a new user
        await _client.auth.signUp(
          email: _email.text.trim(),
          password: _password.text,
        );
      }

      // Provision a tenant on first login/signup. This RPC is defined in
      // `provision_schema.sql` and ensures idempotent creation of org,
      // membership, subscription and branch for the current user.
      await _client.rpc('provision_first_org', params: {
        'p_org_name': 'My First Organisation',
      });

      if (mounted) {
        context.go('/home');
      }
    } on AuthException catch (e) {
      // Display authentication errors to the user.
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(e.message ?? 'Authentication error')),
        );
      }
    } catch (e) {
      // Catch any other error that might occur.
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('An unexpected error occurred: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Sign in'),
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Padding(
            padding: const EdgeInsets.all(24.0),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                TextField(
                  controller: _email,
                  decoration: const InputDecoration(
                    labelText: 'Email',
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _password,
                  obscureText: true,
                  decoration: const InputDecoration(
                    labelText: 'Password',
                  ),
                ),
                const SizedBox(height: 16),
                Row(
                  children: <Widget>[
                    Switch(
                      value: _isLogin,
                      onChanged: (value) {
                        setState(() {
                          _isLogin = value;
                        });
                      },
                    ),
                    Text(_isLogin ? 'Login' : 'Sign Up'),
                    const Spacer(),
                    ElevatedButton(
                      onPressed: _loading ? null : _submit,
                      child: _loading
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : Text(_isLogin ? 'Login' : 'Create account'),
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
}

/// Home page that displays the current organisation and branch information.
/// It also demonstrates a simple insert query scoped to the organisation.
class HomePage extends StatefulWidget {
  const HomePage({super.key});
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final SupabaseClient _client = Supabase.instance.client;
  List<dynamic> _branches = [];
  String? _orgId;

  @override
  void initState() {
    super.initState();
    _loadOrgData();
  }

  Future<void> _loadOrgData() async {
    // Fetch the organisation associated with the current user
    final orgs = await _client.from('organizations').select('id,name,created_at');
    if (orgs.isNotEmpty) {
      _orgId = orgs.first['id'] as String;
      final branches = await _client.from('branches').select('id,name').eq('org_id', _orgId);
      setState(() {
        _branches = branches;
      });
    }
  }

  Future<void> _insertSampleMenuItem() async {
    if (_orgId == null) return;
    await _client.from('menu_items').insert({
      'org_id': _orgId,
      'name': 'Iced Latte',
      'price': 80,
    });
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Inserted menu item for this organisation')),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Home'),
        actions: <Widget>[
          IconButton(
            icon: const Icon(Icons.logout),
            onPressed: () async {
              await _client.auth.signOut();
              if (context.mounted) context.go('/');
            },
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text('Organisation: ${_orgId ?? '-'}'),
            const SizedBox(height: 8),
            const Text('Branches:'),
            const SizedBox(height: 4),
            Expanded(
              child: ListView.builder(
                itemCount: _branches.length,
                itemBuilder: (context, index) {
                  final branch = _branches[index];
                  return ListTile(
                    title: Text(branch['name'] as String),
                    subtitle: Text('ID: ${branch['id']}'),
                  );
                },
              ),
            ),
            const SizedBox(height: 24),
            ElevatedButton(
              onPressed: _insertSampleMenuItem,
              child: const Text('Insert Sample Menu Item'),
            ),
          ],
        ),
      ),
    );
  }
}