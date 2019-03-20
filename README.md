# dart_mssql

High Performance Microsoft SQL Server Driver for Dart (32 & 64bits)

# Important

- Works only on Windows (32bits or 64bits)
- You have to install OLE DB Driver 
- You have to install Microsoft Visual C++ Redistributable
- dart_mssql_32.dll (32-bit) and dart_mssql_64.dll (64-bit) are the compiled versions of the driver. Rename to "dart_mssql.dll" according to your needs and copy it to the main directory of your project.
 
# Example Usage

Demo code to perform Raw SQL queries

```dart
import 'package:dart_mssql/dart_mssql.dart';

void main() async {
  MssqlConnection connection = MssqlConnection("SERVERNAME", "DBNAME", "USERNAME", "PASSWORD");
  int id = 1;
  String cmd = "select * from nacionalidade where id_nacionalidade=$id"; // sorry! param binding not yet implemented!

  SqlResult result = await connection.execute(cmd);
  print("${result.rows.toString()}");
}
```

# Troubleshooting

```
Problem:
The specified module could not be found.
error: library handler failed

Cause:
Missing installing Microsoft OLE DB Driver OR missing dart_mssql.dll file into project main directory OR missing Microsoft Visual C++ Redistributable

Solution:
Copy dart_mssql.dll file into project main directory.


Problem:
%1 is not a valid Win32 application.
error: library handler failed

Cause:
incorrect dart_mssql.dll version (32 bits with dart VM 64 bits or vice versa)

Solution:
Copy correct dart_mssql.dll file into project main directory.


```
# Compile with Microsoft Visual Studio 2017 Community Edition

IF AND ONLY IF you want to compile library source code (C++ part) follow the instructions below:

- Before compile, you have to install Windows 10 SDK on your Microsoft Visual Studio 2017 Community Edition
- Open solution file dart_mssql\cpp\dart_mssql.sln with Microsoft Visual Studio 2017 Community Edition
- On "Solution Explorer" Panel right click on dart_mssql project and select "Rebuild"
- Put the generated dart_mssql.dll file into your project main folder (same folder of your pubspec.yaml file)
- Be sure to have correct dart-sdk\bin folder (32 or 64 bits) in VC++ Directories -> Library Directories. Change "F:\DartSDK64\dart-sdk\bin" to your location
- Be sure to have correct dart.lib version (32 or 64 bits) in Linker -> Input -> Additional Dependencies. Change "F:\DartSDK64\dart-sdk\bin\dart.lib" to your location
