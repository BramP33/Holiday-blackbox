# Flutter 3.35.5 Theme Fix

Quick fix - comment out problematic themes for now:

```bash
cd ~/Holiday-blackbox/Software/flutter_frontend
nano lib/theme.dart

# Comment out these lines:
# Line ~137: cardTheme: CardTheme(
# Line ~189: tabBarTheme: TabBarTheme( 
# Line ~277: dialogTheme: DialogTheme(

# Replace with:
# cardTheme: null,
# tabBarTheme: null, 
# dialogTheme: null,
```

This will allow the build to succeed, then we can fix themes later.