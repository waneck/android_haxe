package android;
import sys.FileSystem.*;
import sys.io.File;
import haxe.macro.Context;
import haxe.macro.Compiler;
using StringTools;
class Run {
  static var androidJarAdded = false;

  static var androidSdk:String = null;
  static var sdkVersion:String = null;
  static var androidTarget:String = null;

  static var resJavaPath:String = null;
  static var resGeneratedPath:String = null;

  static var classPath:String = null;

  static var addedLibs = new Map<String, Bool>();

  static function main() {
    if (!androidJarAdded) {
      androidSdk = Context.definedValue("androidSdk");
      sdkVersion = Context.definedValue("sdkVersion");
      androidTarget = Context.definedValue("androidTarget");
      if (androidTarget == null) {
        androidTarget = "Debug";
        Compiler.define('androidTarget', "Debug");
      }
      var cwd = Sys.getCwd(),
          haxeJson = '${cwd}/../build/intermediates/haxeData.json';
      if (androidSdk == null || sdkVersion == null) {
        if (exists(haxeJson)) {
          var data = haxe.Json.parse(sys.io.File.getContent(haxeJson));
          androidSdk = data.androidSdk;
          sdkVersion = data.sdkVersion;
          Compiler.define('androidSdk', androidSdk);
          Compiler.define('sdkVersion', sdkVersion);
        } else {
          Context.error('Android SDK and version is not set, and no previous compilation was found', Context.currentPos());
        }
      }
      if (androidSdk == null || sdkVersion == null) {
        Context.error('Android SDK and version is not set, and no previous compilation was found', Context.currentPos());
      }

      sys.io.File.saveContent(haxeJson, haxe.Json.stringify({
        androidSdk: androidSdk,
        sdkVersion: sdkVersion,
      }));
      var jar = '$androidSdk/platforms/$sdkVersion/android.jar';
      if (!exists(jar)) {
        Context.error('Cannot find android.jar from sdk: ${androidSdk} ($sdkVersion)', Context.currentPos());
      }
      Compiler.addNativeLib(jar);
      // if (!exists('../build/intermediates/haxe/classes.jar')) {
      // }

      switch(androidTarget) {
        case 'Debug':
          resJavaPath = '$cwd/../build/generated/source/r/debug';
          resGeneratedPath = '$cwd/generated/debug';
          classPath = "src/main";
        case 'DebugAndroidTest':
          resJavaPath = '$cwd/../build/generated/source/r/androidTest/debug';
          resGeneratedPath = '$cwd/generated/androidTestDebug';
          return; // TODO add support for this
          // classPath = "src/androidTest";
        case 'DebugUnitTest':
          return; // TODO add support for this
          // classPath = "src/test";
        case _:
          Context.error('Unknown android target $androidTarget', Context.currentPos());
      }
      if (!exists(resGeneratedPath)) {
        createDirectory(resGeneratedPath);
      }
      Compiler.addClassPath(classPath);
      Compiler.addClassPath(resGeneratedPath);
      androidJarAdded = true;
    }
    recursiveResCheck(resJavaPath, resGeneratedPath, '');
    if (exists('../build/intermediates/haxeDeps.txt')) {
      for (lib in File.getContent('../build/intermediates/haxeDeps.txt').split('\n')) {
        if (!addedLibs[lib]) {
          Compiler.addNativeLib(lib);
          addedLibs[lib] = true;
        }
      }
    }
    for (file in collectSources(classPath)) {
      Context.getModule(file);
    }
  }

  private static function recursiveResCheck(javaPath:String, genPath:String, pack:String) {
    for (file in readDirectory(javaPath)) {
      var path = '$javaPath/$file';
      if (file.endsWith('.java')) {
        var name = file.substr(0, file.length - 5);
        var haxePath = '$genPath/$name.hx';
        if (!exists(haxePath) || stat(path).mtime.getTime() >= stat(haxePath).mtime.getTime()) {
          if (!exists(genPath)) {
            createDirectory(genPath);
          }
          android.haxe.ResTranslator.javaToHaxe(path, haxePath);
        }
      } else if (isDirectory(path)) {
        recursiveResCheck(path,'$genPath/$file', '$pack$file.');
      }
    }
  }

  private static function collectSources(basePath:String):Array<String> {
    var ret = [];
    function recurse(dir:String, pack:String) {
      for (file in readDirectory(dir)) {
        var path = '$dir/$file';
        if (file.substr(-3).toLowerCase() == '.hx') {
          ret.push(pack + file.substr(0,file.length-3));
        } else if (file != 'android' && isDirectory(path)) {
          recurse(path, pack + file + '.');
        }
      }
    }
    recurse(basePath, '');
    return ret;
  }

  // private static function compileClassesJar() {
  //   var allFiles = collectFiles('$androidSdk/sources/$sdkVersion/android/support', '.java');
  //   var outDir = '${Sys.getCwd()}/../build/intermediates/haxe';
  //   if (!exists(outDir)) {
  //     createDirectory(outDir);
  //   }
  //   // var descriptor = sys.io.File.write('$outDir/native-compilation.txt', false);
  //   var descriptor = new StringBuf();
  //   descriptor.add('$outDir\n');
  //   // var opts = ['-sourcep];
  //   descriptor.add('begin modules\n');
  //   descriptor.add('M Native\n');
  //   for (f in allFiles) {
  //     descriptor.add('F $f\n');
  //   }
  //   descriptor.add('end modules\n');
  //   descriptor.add('begin libs\n');
  //   descriptor.add('$androidSdk/platforms/$sdkVersion/android.jar\n');
  //   descriptor.add('$androidSdk/platforms/$sdkVersion/android-stubs-src.jar\n');
  //   descriptor.add('$androidSdk/platforms/$sdkVersion/data/layoutlib.jar\n');
  //   descriptor.add('end libs\n');
  //   sys.io.File.saveContent('$outDir/native-compilation.txt', descriptor.toString());
  //   if (Sys.command('haxelib', ['run','hxjava','$outDir/native-compilation.txt']) != 0) {
  //     Context.error('Native compilation of classes.jar failed', Context.currentPos());
  //   }
  // }
}
