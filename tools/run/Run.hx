import mcli.Dispatch;
import mcli.CommandLine;
import sys.FileSystem.*;
import sys.io.File;

class Run extends CommandLine {
  public static var haxelibPath = null;

  static function main() {
    var args = Sys.args();
    if (Sys.getEnv("HAXELIB_RUN") == "1") {
      haxelibPath = Sys.getCwd();
      var newPath = args.pop();
      Sys.setCwd(newPath);
      Sys.putEnv("HAXELIB_RUN", "");
    } else {
      haxelibPath = haxe.io.Path.directory(Sys.programPath());
    }

    new Dispatch(args).dispatch(new Run());
  }

  /**
    Initializes android-haxe into a new android project
   **/
  public function init(d:Dispatch) {
    d.dispatch(new Init());
  }

  /**
    Updates an android project that already uses  android-haxe with the latest version
   **/
  public function update(d:Dispatch) {
    d.dispatch(new Update());
  }

  public static function initOrUpdate(path:String, update:Bool) {
    if (!exists('$haxelibPath/templates')) {
      throw 'android-haxe project does not contain a tempaltes folder (located at $haxelibPath)';
    }
    if (exists('$path/app')) {
      path = '$path/app';
    }
    if (exists('$path/haxe') && !update) {
      throw 'The project at $path already seems to have been initialized. Try running `update` instaed of `init`';
    }

    File.copy('$haxelibPath/templates/haxe.gradle', '$path/haxe.gradle');
    if (!update) {
      var build = File.getContent('$path/build.gradle').split('\n');
      build.insert(1, "apply from: 'haxe.gradle'");
      var androidRegex = ~/^\s*android\s*\{\s*/i,
          found = false;
      for (i in 0...build.length) {
        if (androidRegex.match(build[i])) {
          found = true;
          build.insert(i+1, '    sourceSets {');
          build.insert(i+2, '        main.java.srcDirs += "build/generated/haxe/src"');
          build.insert(i+3, '    }');
          break;
        }
      }
      if (!found) {
        throw 'Could not find android directive on $path/build.gradle';
      }
      File.saveContent('$path/build.gradle', build.join('\n'));
      createDirectory('$path/haxe/src/main');
      // TODO support androidTest/test
      // createDirectory('$path/haxe/src/androidTest');
      // createDirectory('$path/haxe/src/test');
      File.copy('$haxelibPath/templates/haxe/build.hxml', '$path/haxe/build.hxml');
    }
  }
}

class Init extends mcli.CommandLine {
  public function runDefault(?path:String) {
    if (path == null) {
      path = Sys.getCwd();
    }
    Run.initOrUpdate(path, false);
  }
}

class Update extends CommandLine {
  public function runDefault(?path:String) {
    if (path == null) {
      path = Sys.getCwd();
    }
    Run.initOrUpdate(path, true);
  }
}
