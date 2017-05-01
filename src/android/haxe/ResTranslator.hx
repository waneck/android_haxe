package android.haxe;
import android.haxe.Java;
import android.haxe.Parser;

class ResTranslator {
  public static function javaToHaxe(javaFile:String, targetHaxeFile:String) {
    var buf = new StringBuf();
    var program:Program = null;
    var parser = new Parser(true);
    try {
      program = parser.parse(sys.io.File.read(javaFile, false), javaFile);
    }
    catch(e:Error) {
      var pos = parser.getPos();
      switch(e) {
        case EInvalidChar( c ):
          throw new haxe.macro.Expr.Error('Invalid character \'${String.fromCharCode(c)}\'', haxe.macro.Context.makePosition(pos));
        case EUnexpected( s ):
          throw new haxe.macro.Expr.Error('Unexpected \'${s}\'', haxe.macro.Context.makePosition(pos));
        case EUnterminatedString:
          throw new haxe.macro.Expr.Error('Unterminated String', haxe.macro.Context.makePosition(pos));
        case EUnterminatedComment:
          throw new haxe.macro.Expr.Error('Unterminated Comment', haxe.macro.Context.makePosition(pos));
      }
    }
    catch(e:Dynamic) {
      var pos = parser.getPos();
      throw new haxe.macro.Expr.Error('Unknown Error: $e', haxe.macro.Context.makePosition(pos));
    }

    var pack = program.pack.join('.');
    buf.add('package ');
    buf.add(pack);
    buf.add(';\n\n');

    var bufs = [];
    for (def in program.defs) {
      processDef(pack, def, [], bufs);
    }

    var write = sys.io.File.write(targetHaxeFile, false);
    write.writeString(buf.toString());
    for (buf in bufs) {
      write.writeByte('\n'.code);
      write.writeString(buf.toString());
    }
    write.close();
  }

  private static function processDef(pack:String, def:Definition, indent:Array<String>, bufs:Array<StringBuf>):Void {
    switch(def) {
    case CDef(c):
      var prefix = indent.join('_');
      var javaName = indent.join('.');
      indent.push(c.name);
      var buf = new StringBuf(),
          externBuf = new StringBuf();
      bufs.push(buf);
      bufs.push(externBuf);
      if (prefix != '') {
        buf.add('private ');
        prefix += '_';
        javaName += ".";
      }
      var kwds = '';
      if (prefix.length == 0) {
        kwds = 'static ';
      }
      buf.add('extern abstract ');
      buf.add(prefix + c.name);
      buf.add('(Dynamic)');
      buf.add(' {\n');

      externBuf.add('@:native("$pack.${indent.join("$")}") ');
      externBuf.add('@:javaCanonical("$pack","${javaName}${c.name}") ');
      externBuf.add('private extern class ');
      externBuf.add('_Java_' + prefix + c.name);
      externBuf.add(' {\n');

        for (f in c.fields) {
          if (f.kwds == null || f.kwds.indexOf('static') < 0) {
            haxe.macro.Context.warning('Field is not static: ${f.name}', haxe.macro.Context.makePosition(f.pos));
            continue;
          }
          var type = null;
          switch(f.kind) {
          case FVar(t,_):
            if (t.t.match(TPath(["int"],_))) {
              type = 'Int';
            } else if (t.t.match(TArray(TPath(["int"],_)))) {
              type = 'haxe.ds.Vector<Int>';
            } else {
              haxe.macro.Context.warning('Field is not int/int[]: ${f.name}', haxe.macro.Context.makePosition(f.pos));
              continue;
            }
          case FFun(_):
            haxe.macro.Context.warning('Field is a function: ${f.name}', haxe.macro.Context.makePosition(f.pos));
            continue;
          }
          if (f.comments != null) {
            for (comment in f.comments) {
              switch(comment.expr) {
              case JComment(s, true):
                buf.addChar('\t'.code);
                buf.add(s);
                buf.addChar('\n'.code);
              case _:
              }
            }
          }
          externBuf.add('\tpublic static var ${f.name}(default,never):$type;\n');
          buf.add('\tpublic ${kwds}var ${f.name}(get,never):$type;\n');
          buf.add('\t@:extern inline ${kwds}function get_${f.name}():$type { return _Java_${prefix}${c.name}.${f.name}; }\n');
        }
        for (child in c.childDefs) {
          switch(child) {
          case CDef(cChild):
            var cName = prefix + c.name + '_' + cChild.name;
            buf.add('\tpublic ${kwds}var ${cChild.name}(get,never):${cName};\n');
            buf.add('\t@:extern inline ${kwds}function get_${cChild.name}():${cName} { return null; }\n');
          case _:
          }
          processDef(pack, child, indent, bufs);
        }
      buf.add('}');
      externBuf.add('}');
      indent.pop();
    case EDef(e):
      haxe.macro.Context.warning('Enum definition on resource', haxe.macro.Context.makePosition(e.pos));
    }
  }
}
