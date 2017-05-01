package android.haxe;

import android.haxe.Java;
import haxe.ds.GenericStack;
import haxe.ds.StringMap;
import haxe.PosInfos;
using Lambda;

enum Error {
  EInvalidChar( c : Int );
  EUnexpected( s : String );
  EUnterminatedString;
  EUnterminatedComment;
}

enum Token {
  TEof;
  TConst( c : Const );
  TId( s : String );
  TOp( s : String );
  TPOpen; // (
  TPClose; // )
  TBrOpen; // [
  TBrClose; // ]
  TDot; // .
  TComma; // ,
  TSemicolon; // ;
  TBkOpen; // {
  TBkClose; // }
  TQuestion; // ?
  TDoubleDot; // :
  TAt; // @
  TNs; // ::
  TComment( s : String, isBlock : Bool );
}

class Parser {

  // config / variables
  public var line : Int;
  public var identChars : String;
  public var opPriority : StringMap<Int>;
  public var unopsPrefix : Array<String>;
  public var unopsSuffix : Array<String>;

  var onlyDefinitions : Bool;

  // implementation
  var file : String;
  var input : haxe.io.Input;
  var char : Int;
  var ops : Array<Bool>;
  var idents : Array<Bool>;
  var tokens : GenericStack<Token>;
  var no_comments : Bool;
  var lastComments : Array<Token>;
  var watchingComments : Bool;

  var pos:Int;

  public function new(onlyDefinitions = false) {
    this.onlyDefinitions = onlyDefinitions;
    lastComments = [];
    line = 1;
    watchingComments = true;
    identChars = "$ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_";
    var p = [
      ["%", "*", "/"],
      ["+", "-"],
      ["<<", ">>", ">>>"],
      [">", "<", ">=", "<="],
      ["==", "!="],
      ["&"],
      ["^"],
      ["|"],
      ["&&"],
      ["||"],
      ["?:"],
      ["=", "+=", "-=", "*=", "%=", "/=", "<<=", ">>=", ">>>=", "&=", "^=", "|=", "&&=", "||="]
    ];
    opPriority = new StringMap();
    for( i in 0...p.length )
      for( op in p[i] )
        opPriority.set(op, i);
    unopsPrefix = ["!", "++", "--", "-", "+", "~"];
    for( op in unopsPrefix )
      if( !opPriority.exists(op) )
        opPriority.set(op, -1);
    unopsSuffix = ["++", "--"];
    no_comments = false;
  }

  public function parseString( s : String, asFile:String ) : Program {
    return parse( new haxe.io.StringInput(s), asFile );
  }

  public function parse( s : haxe.io.Input, asFile:String ) : Program {
    this.file = asFile;
    line = 1;
    char = 0;
    pos = 0;
    input = s;
    ops = new Array();
    idents = new Array();
    tokens = new GenericStack<Token>();
    for( op in opPriority.keys() )
      for( i in 0...op.length )
        ops[op.charCodeAt(i)] = true;
    for( i in 0...identChars.length )
      idents[identChars.charCodeAt(i)] = true;
    return parseProgram();
  }

  inline function add(tk) {
    tokens.add(tk);
  }

  function opt(tk,ncmnt=true) {
    var f = function() {
      var t = token();
      if( Type.enumEq(t, tk) )
        return true;
      add(t);
      return false;
    }
    return ncmnt ? ignoreComments(f) : f();
  }

  function ensure(tk) {
    ignoreComments(function() {
      var t = token();
      if( !Type.enumEq(t, tk) )
        unexpected(t);
      return null;
    });
  }

  function ignoreComments(f:Void->Dynamic) : Dynamic {
    var old = no_comments;
    no_comments = true;
    var rv = f();
    no_comments = old;
    return rv;
  }

  function parseProgram() : Program {
    #if debug trace("parseProgram()"); #end
    var pack = [];
    var header:Array<Expr> = [];
    while (true) {
      var min = pos;
      var t = token();
      switch(t) {
      case TId(s):
        if( s != "package" )
        {
          add(t);
          break;
        }
        if( opt(TSemicolon) )
          pack = []
        else {
          pack = parsePackage();
          ensure(TSemicolon);
        }
        break;
      case TComment(s,b):
        header.push(mk(JComment(s,b), min));
      default:
        unexpected(t);
      }
    }
    var imports = [];
    var defs = [];
    var metas = null;
    while ( true ) {
      var tpos = pos;
      var tk = token();
      switch( tk ) {
      case TEof:
        break;
      case TAt:
        add(tk);
        metas = parseMetadata();
        continue;
      case TId(id):
        switch( id ) {
        case "import":
          imports.push(parseImport());
          continue;
        case "public", "class", "enum", "protected", "private", "abstract", "static", "final", "strictfp", "interface":
          add(tk);
          defs.push(parseDefinition(tpos, header, metas));
          header = [];
          metas = null;
          continue;
        default:
        }
      case TComment(s,b):
        header.push(mk(JComment(s,b), tpos));
        continue;
      case TSemicolon:
        end();
        continue;
      default:
      }
      unexpected(tk);
    }
    var name = switch(defs[0])
    {
      case EDef(e): e.name;
      case CDef(c): c.name;
    };

    //defs will always have one element only
    //if (defs.length != 1) throw "unexpected";
    return {
      //header : header,
      pack : pack,
      imports : imports,
      defs : defs,
      name : name,
    };
  }

  function parseImport() {
    #if debug trace("parseImport()"); #end
    var isStatic = opt(TId("static"));
    var a = [id()];

    while( true ) {
      var tk = token();
      switch( tk ) {
      case TDot:
        tk = token();
        switch(tk) {
        case TId(id): a.push(id);
        case TOp(op):
          if( op == "*" ) {
            a.push(op);
            ensure(TSemicolon);
            break;
          }
          unexpected(tk);
        default: unexpected(tk);
        }
      case TSemicolon:
        end();
        break;
      default:
        unexpected(tk);
      }
    }
    return { path:a, isStatic:isStatic };
  }

  function parseMetadata(?pinfo:PosInfos) {
    #if debug haxe.Log.trace("parseMetadata()", pinfo); #end
    var ml = [];
    while( opt(TAt) ) {
      var min = pos;
      var name = id();
      if (name == "interface")
      {
        add(TId("_interface"));
        //add(TAt);
        return ml;
      }

      while (opt(TDot))
      {
        name += "." + id();
      }
      var args = null;
      if ( opt(TPOpen) )
      {
        //TODO parse expressions correctly
        var n = 1;
        while( n > 0)
        {
          switch(token())
          {
          case TPOpen: n++;
          case TPClose: n--;
          default:
          }
        }
        //args = parseExprList(TPClose);
      }
      ml.push( { name : name, args : args, pos : mkPos(min) } );
    }
    return ml;
  }

  function parseDefinition(min:Int, comments, meta) {
    #if debug trace("parseDefinition()"); #end
    var kwds = [];
    //var meta = parseMetadata();
    while ( true ) {
      if (peek() == TAt)
      {
        token();
        ensure(TId("interface"));

        add(TId("_interface"));
      }

      var id = id();
      switch( id ) {
      case "public", "protected", "private", "abstract", "static", "strictfp", "final": kwds.push(id);
      case "class":
        var ret = CDef(parseClass(kwds, meta, min, comments, true));
        end();
        return ret;
      case "_interface":
        kwds.push("_interface");
        var c = parseClass(kwds, meta, min, comments, true);
        c.isInterface = true;
        return CDef(c);
      case "interface":
        var c = parseClass(kwds, meta, min, comments, true);
        end();
        c.isInterface = true;
        return CDef(c);
      case "enum":
        var e = parseEnum(kwds, meta, min, comments, true);
        end();
        return EDef(e);
      default: unexpected(TId(id));
      }
    }
    return null;
  }

  function parseTypeParameters() : Array<GenericDecl>
  {
    var ret = [];
    if (opt(TOp("<")))
    {
      while (true)
      {
        var name = id();
        var ext = null;
        if (opt(TId("extends")))
        {
          ext = [ parseType() ];
          while (opt(TOp("&")))
          {
            ext.push(parseType());
          }
        }

        opt(TComma);
        ret.push( { name : name, extend : ext } );

        if (opt(TOp(">")))
          break;
      }

    }

    return ret;
  }

  function parseEnum(kwds, meta, min, header, isRoot) : EnumDef
  {
    var ename = id();
    //var types = parseTypeParameters();
    var fields = new Array();
    var impl = [], staticInit = null, instInit = null;
    if( opt(TId("implements")) ) {
      impl.push(parseType());
      while( opt(TComma) )
        impl.push(parseType());
    }

    ensure(TBrOpen);
    //parse constructors

    var constrs = [];
    var comments = [];
    while (true)
    {
      var min = pos;
      var meta = parseMetadata();

      var tk = lastComments.pop();
      if (tk == null)
        tk = token();
      else
        lastComments = [];
      switch(tk)
      {
      case TBrClose:
        add(tk);
        break;
      case TSemicolon:
        end();
        break;
      case TId(id):

        var args = null;
        if (opt(TPOpen))
        {
          args = [];
          while( !opt(TPClose) ) {
            var e = parseExpr(true);
            args.push( e );
            opt(TComma);
          }
        }

        //TODO java.awt.font.NumericShaper
        if (opt(TBrOpen))
        {
          var tbr = 1;
          while (tbr > 0)
          {
            switch(token())
            {
              case TBrClose: tbr--;
              case TBrOpen: tbr++;
              default:
            }
          }
        }

        constrs.push( {
          name : id,
          args : args,
          meta : meta,
          pos : mkPos(min),
          comments : comments
        });

        comments = [];
      case TComma:
      case TComment(s, b):
        comments.push(mk(JComment(s,b), min));
      default:
        unexpected(tk);
      }
    }

    var fields = parseFields();

    return {
      comments : header,
      meta : meta,
      kwds : kwds,
      //types : types,
      name : ename,
      implement : impl,

      childDefs : fields.childDefs,
      isRoot : isRoot,
      constrs : constrs,
      fields : fields.fields,
      staticInit : fields.staticInit,
      instInit : fields.instInit,
      pos : mkPos(min)
    }
  }

  function mkPos(min:Int, ?max=0)
  {
    if (max == 0) max = pos;
    return { min : min, max : max, file:file };
  }

  public function getPos() {
    return mkPos(pos);
  }

  function parseClass(kwds:Array<String>,meta, min, header, isRoot) : ClassDef {
    var cname = id();
    #if debug trace("parseClass(" + cname + ")"); #end
    var types = parseTypeParameters();
    var fields = new Array();
    var impl = [], extend = [], staticInit = null, instInit = null;
    while( true ) {
      if( opt(TId("implements")) ) {
        impl.push(parseType());
        while( opt(TComma) )
          impl.push(parseType());
        continue;
      }
      if ( opt(TId("extends")) ) {
        extend.push(parseType());
        while( opt(TComma) )
          extend.push(parseType());
        continue;
      }
      break;
    }
    ensure(TBrOpen);

    var fields = null;
    if (kwds.has("_interface"))
    {
      //TODO
      fields = { staticInit:null, instInit:null, fields:[], childDefs:[] };
      var tbr = 1;
      while (tbr > 0)
      {
        switch(token())
        {
        case TBrClose: tbr--;
        case TBrOpen: tbr++;
        default:
        }
      }
    } else {
      fields = parseFields();
    }

    #if debug trace("parseClass("+cname+") finished"); #end
    return {
      comments : header,
      kwds : kwds,
      isInterface : false,
      meta : meta,
      name : cname,
      types : types,
      childDefs : fields.childDefs,
      isRoot : isRoot,
      fields : fields.fields,
      implement : impl,
      extend : extend,
      staticInit : fields.staticInit,
      instInit : fields.instInit,
      pos : mkPos(min)
    };
  }

  function parseFields() : { fields : Array<ClassField>, staticInit:Null<Expr>, instInit:Null<Expr>, childDefs:Array<Definition> }
  {
    var fields = [], staticInit = null, instInit = null, childDefs = [];
    while( true ) {
      if ( opt(TBrClose) ) break;
      var meta = parseMetadata();
      var min = pos;
      var kwds = [];
      var comments = [];
      var lastTypes = null;
      var lastComment = null;
      while ( true )  {
        var t = lastComments.pop();
        if (t == null)
          t = token();
        else
          lastComments = [];

        switch( t ) {
        case TBrOpen:
          add(t);
          var expr = parseExpr(false, true);
          if (kwds.has("static"))
          {
            if (staticInit != null)
              throw "More than one static init";
              staticInit = expr;
          } else {
            if (staticInit != null)
              throw "More than one instance init";
            instInit = expr;
          }
          end();

          break;
        case TId(id):
          switch( id ) {
          case "public", "static", "private", "protected", "abstract", "native", "synchronized", "transient", "volatile", "strictfp", "final": kwds.push(id);
          case "class", "interface", "_interface":
            var c1 = parseClass(kwds, meta, min, lastComment, false);
            end();
            var c = CDef(c1);
            if (id == "interface")
              c1.isInterface = true;
            lastComment = null;
            childDefs.push(c);
            break;
          case "enum":
            var e = EDef(parseEnum(kwds, meta, min, lastComment, false));
            end();
            lastComment = null;
            childDefs.push(e);
            break;
          default:
            add(t);
            //first parse type
            parseMetadata();
            var t = parseType();
            #if debug trace(t); #end

            var name = null;
            if (peek() == TPOpen) //it's the constructor
            {
              name = switch(t.t)
              {
              case TPath(p, _): p[0];
              default: throw "assert";
              };
              t.t = TPath(["void"], []);
            } else {
              name = this.id();
            }

            var fnMin = pos;
            if (opt(TPOpen)) //is it a function?
            {
              add(TPOpen);
              var args = parseFunArgs();

              while (opt(TBkOpen))
              {
                var tk = token();
                if (tk != TBkClose)
                  unexpected(tk);
                t.t = TArray(t.t);
              }

              var throws = [];
              if (opt(TId("throws")))
              {
                while (true)
                {
                  throws.push( parseType() );
                  if (!opt(TComma))
                    break;
                }
              }

              var expr = null;
              if (opt(TBrOpen))
              {
                add(TBrOpen);
                expr = parseExpr(false, true);
              } else {
                end();
              }

              var lt = lastTypes;
              lastTypes = null;

              fields.push( {
                comments: lastComment,
                kwds : kwds,
                meta : meta,
                name : name,
                types : lt,
                kind : FFun({
                  args : args.args,
                  varArgs : args.varArgs,
                  ret : t,
                  throws : throws,
                  expr : expr,
                  pos : mkPos(fnMin)
                }),
                pos : mkPos(min)
              } );

              end();

              lastComment = null;
            } else {
              do
              {
                if (name == null)
                {
                  name = this.id();
                }

                var val = null;
                while (opt(TBkOpen))
                {
                  var tk = token();
                  if (tk != TBkClose)
                    unexpected(tk);
                  t.t = TArray(t.t);
                }

                if (opt(TOp("=")))
                {
                  if (onlyDefinitions)
                  {
                    var nbr = 0;
                    var foundSemi = false;
                    while (!foundSemi)
                    {
                      switch(token())
                      {
                        case TSemicolon if (nbr == 0):
                          foundSemi = true;
                        case TBrOpen: nbr++;
                        case TBrClose: nbr--;
                        default:
                      }
                    }
                  } else {
                    val = parseExpr(true);
                  }
                }


                var lt = lastTypes;
                lastTypes = null;
                fields.push({
                  comments : lastComment,
                  kwds: kwds,
                  meta : meta,
                  name : name,
                  types : lt,
                  kind : FVar(t, val),
                  pos : mkPos(min)
                });

                lastComment = null;
                name = null;
                if (opt(TSemicolon)) { end(); break; }
              } while (opt(TComma));
            }

            break;
          }
        case TComment(s, b):
          if (lastComment != null)
          {
            lastComment.push(mk( JComment(s, b), min ));
          } else {
            lastComment = [mk( JComment(s, b), min )];
          }
        case TOp(op):
          if (op == "<") // start of generics
          {
            add(t);
            lastTypes = parseTypeParameters();
          } else {
            unexpected(t);
          }
        case TAt:
          add(TAt);
          if (meta != null)
            meta = meta.concat(parseMetadata());
          else
            meta = parseMetadata();
        default:
          unexpected(t);
          break;
        }
      }
    }

    return { fields : fields, staticInit : staticInit, instInit : instInit , childDefs : childDefs };
  }

  function mk(e:ExprExpr, min:Int, ?max:Int = 0)
  {
    return { expr : e, pos : mkPos(min, max) };
  }

  function parseType(?parseArray=true) {
    #if debug trace("parseType(" + parseArray + ")"); #end
    var t = id();

    var isFinal = false;
    if (t == "final")
    {
      isFinal = true;
      if (peek() == TAt) parseMetadata();
      t = id();
    }

    var a = [t];
    while( true ) {
      var tk = token();
      switch( tk ) {
      case TDot:
        tk = token();
        switch(tk) {
        case TId(id): a.push(id);
        case TDot: //... for varArgs
          add(tk);
          add(tk);
          break;
        default: unexpected(tk);
        }
      case TComment(_,_):
      default:
        add(tk);
        break;
      }
    }

    var params = [];
    if (opt(TOp("<<")))
    {
      add(TOp("<"));
      add(TOp("<"));
    }

    if (opt(TOp("<")))
    {
      while (true)
      {
        var tk = token();
        switch(tk)
        {
        case TQuestion:
          if (opt(TId("extends")))
          {
            params.push(AWildcardExtends(parseType()));
          } else if (opt(TId("super"))) {
            params.push(AWildcardSuper(parseType()));
          } else {
            params.push(AWildcard);
          }

          continue;
        case TOp(">"):break;
        case TOp(">>"): add(TOp(">")); break;
        case TOp(">>>"): add(TOp(">"));add(TOp(">")); break;
        case TId(_):
          add(tk);
          params.push(AType(parseType()));
        case TComma, TDot:
          continue;
        default:
          unexpected(tk);
        }
      }
    }

    var ret = TPath(a, params);
    if (parseArray)
    {
      while (opt(TBkOpen))
      {
        ensure(TBkClose);
        ret = TArray(ret);
      }
    }


    return { final : isFinal, t: ret };
  }

  function parseFunArgs(): { args:Array<{name:String, t:T}>, varArgs: Null<{ name:String, t:T }> }
  {
    var varArgs = null;
    var args = [];
    ensure(TPOpen);
    if (!opt(TPClose))
    {
      while ( true ) {
        if (opt(TPClose))
        {
          return { args : args, varArgs : null }
        }
        parseMetadata();
        var type = parseType();
        if (opt(TDot))
        {
          ensure(TDot);
          ensure(TDot);

          while (opt(TBkOpen))
          {
            ensure(TBkClose);
            type.t = TArray(type.t);
          }

          varArgs = { name : id(), t : type };
          ensure(TPClose);

          return { args : args, varArgs: varArgs };
        }
        var name = id();

        while (opt(TBkOpen))
        {
          ensure(TBkClose);
          type.t = TArray(type.t);
        }
        opt(TComma);
        args.push( { name : name, t : type } );
      }
    } else {
      return { args : args, varArgs : null };
    }
    throw "assert";
  }

  function parsePackage() {
    #if debug trace("parsePackage()"); #end
    var a = [id()];
    while( true ) {
      var tk = token();
      switch( tk ) {
      case TDot:
        tk = token();
        switch(tk) {
        case TId(id): a.push(id);
        default: unexpected(tk);
        }
      default:
        add(tk);
        break;
      }
    }
    return a;
  }

  function unexpected( tk ) : Dynamic {
    throw EUnexpected(tokenString(tk));
    return null;
  }

  function end() {
    while( opt(TSemicolon) ) {
    }
  }

  function parseCastOrParen() : Expr
  {
    #if debug trace("parseCast()"); #end
    var min = this.pos;

    if (isTypeDefinition())
    {
      #if debug trace("\t Is cast "); #end
      //is cast
      var t = parseType();
      ensure(TPClose);

      var exp = parseExpr(true);

      function addExpr(to:Expr)
      {
        switch(to.expr)
        {
        case JBinop(op, e1, e2):
          return mk(JBinop(op,addExpr(e1),e2), to.pos.min, to.pos.max);
        default:
          return mk(JCast(t, to), min, to.pos.max);
        }
      }

      return addExpr(exp);
    } else {
      #if debug trace("\t Is parenthesis "); #end
      var e = parseExpr(true);
      ensure(TPClose);

      return mk(JParent(e), min);
    }
  }

  function isTypeDefinition():Bool
  {
    #if debug trace("isTypeDefinition()"); #end
    var toRollback = [];

    var genDecl = 0;
    var hadId = false;
    var idMin = 0;

    if (opt(TId("final")))
    {
      toRollback.push(TId("final"));
    } else {
      while (true)
      {
        idMin = pos;
        var tk = token();
        toRollback.push(tk);
        switch(tk)
        {
          case TId(s):
            switch(s)
            {
              case "return", "assert", "instanceof", "break", "continue", "throw", "if", "super", "native":
                while (toRollback.length > 0) add(toRollback.pop());
                return false;
            }

            if (hadId && genDecl == 0)
            {
              //is var declaration
              break;
            } else {
              hadId = true;
            }
          case TDot:
            if (!hadId) {
              while (toRollback.length > 0) add(toRollback.pop());
              return false;
            }

            hadId = false;
          case TOp(op):
            switch(op)
            {
            case "<": genDecl++;
            case "<<": genDecl += 2;
            case ">>": if ( (genDecl -= 2) < 0) {while (toRollback.length > 0) add(toRollback.pop()); return false;}
            case ">>>": if ( (genDecl -= 3) < 0) {while (toRollback.length > 0) add(toRollback.pop()); return false;}
            case ">": if (genDecl-- < 0) {while (toRollback.length > 0) add(toRollback.pop()); return false;}
            default: while (toRollback.length > 0) add(toRollback.pop()); return false;
            }
          case TComma if (genDecl == 0): break;
          case TComma, TQuestion if (genDecl > 0):
          case TPClose if (genDecl == 0): break;
          case TBkOpen:
            if (peek() != TBkClose)
            {
              while (toRollback.length > 0) add(toRollback.pop()); return false;
            } else {
              toRollback.push(token());
            }
          default:
            while (toRollback.length > 0) add(toRollback.pop()); return false;
        }
      }
    }

    #if debug trace("\t -> is type definition"); #end
    while (toRollback.length > 0) add(toRollback.pop());
    return true;
  }

  function parseVarDecl() : Null<Expr>
  {
    #if debug trace("parseVarDecl()"); #end
    var min = pos;

    if (!isTypeDefinition())
      return null;

    #if debug trace("\t Is var declaration "); #end
    var vars = [];

    var t = parseType();
    var first = true;
    while (true)
    {
      var name = id();
      var e = null;

      while (first && opt(TBkOpen))
      {
        ensure(TBkClose);
        t.t = TArray(t.t);
      }

      if (opt(TOp("=")))
      {
        e = parseExpr(true);
      }

      vars.push( { name : name, t : t, val : e } );
      if (!opt(TComma))
        break;

      first = false;
    }

    #if debug trace("\t->Vars " + vars); #end
    return mk(JVars(vars), min);
  }

  function parseFullExpr() {
    #if debug trace("parseFullExpr()"); #end
    var min = pos;
    var lst = watchingComments;
    watchingComments = false;

    var tk = token();
    var isFinal = false;
    switch(tk)
    {
    case TId(id):
      if (opt(TDoubleDot))
      {
        return parseExpr(false, false, id);
      } else {
        add(tk);
      }
    case TComment(_,_): //add to possible rollback
    default:
      add(tk);
    }

    var e = parseVarDecl();
    if (e == null)
      e = parseExpr(false);

    watchingComments = lst;
    return e;
  }

  function parseExpr(inValue:Bool, funcStart:Bool = false, namedExpr:String = null):Expr {
    if (onlyDefinitions && funcStart)
    {
      var indent = 0;
      do
      {
        switch(token())
        {
          case TBrOpen: indent++;
          case TBrClose: indent--;
          default:
        }
      } while (indent > 0);

      return null;
    }

    var min = pos;
    var tk = token();
    #if debug trace("parseExpr("+tk+")"); #end
    switch( tk ) {
    case TId(id):
      var e = parseStructure(id, namedExpr, min);
      if( e == null )
        e = mk(JIdent(id), min);
      if ( peek() == TSemicolon || peek() == TComma )
        return e;
      return parseExprNext(e);
    case TConst(c):
      return parseExprNext(mk(JConst(c), min));
    case TPOpen:

      var e = parseCastOrParen();
      //var e = parseExpr();
      //ensure(TPClose);
      return parseExprNext(e);
    case TBrOpen if (inValue): //array declaration
      var decls = [];
      while (!opt(TBrClose))
      {
        decls.push(parseExpr(true));
        opt(TComma);
      }

      return mk(JArrayDecl(null, null, decls), min);
    case TBrOpen:
      #if debug trace("parseExpr: "); #end
      var a = new Array();
      while( !opt(TBrClose) ) {
        var e = parseFullExpr();
        end();
        a.push(e);
      }
      return mk(JBlock(a), min);
    case TOp(op):
      var found;
      for( x in unopsPrefix )
        if( x == op )
          return makeUnop(op, parseExpr(true), min);
      return unexpected(tk);
    case TComment(s,b):
      return mk(JComment(s,b), min);
    default:
      return unexpected(tk);
    }
  }

  function makeUnop( op, e:Expr, min, ?max:Int=0 ) {
    return switch( e.expr ) {
    case JBinop(bop,e1,e2): mk(JBinop(bop,makeUnop(op,e1, e1.pos.min, e1.pos.max),e2), min, max);
    default: mk(JUnop(op,true,e), min);
    }
  }

  function makeBinop( op, e1, e:Expr, min, max=0 ) {
    return switch( e.expr ) {
    case JTernary(cond, e1, e2):
      if (op == "==" || op == "!=" || op.charCodeAt(op.length-1) != '='.code)
        mk(JTernary( mk(JBinop(op, e1, cond), min, max), e1, e2 ), min, e.pos.max);
      else
        mk(JBinop(op,e1,e), min, max);
    case JBinop(op2, e2, e3):
      var p1 = opPriority.get(op);
      var p2 = opPriority.get(op2);
      if( p1 < p2 || (p1 == p2 && op.charCodeAt(op.length-1) != "=".code) )
        mk(JBinop(op2,makeBinop(op,e1,e2, min, e2.pos.max),e3), min, max);
      else
        mk(JBinop(op,e1,e), min, max);
    default: mk(JBinop(op,e1,e), min, max);
    }
  }

  function parseStructure(kwd, namedExpr, min) : Expr {
    #if debug trace("parseStructure(): "+kwd); #end
    return switch( kwd ) {
    case "if":
      ensure(TPOpen);
      var cond = parseExpr(true);
      ensure(TPClose);
      var e1 = parseExpr(false);
      end();
      var e2 = if( opt(TId("else"), true) ) parseExpr(false) else null;
      mk(JIf(cond,e1,e2), min);
    case "final":
      throw "assert";
    case "while":
      ensure(TPOpen);
      var econd = parseExpr(true);
      ensure(TPClose);
      var e = parseExpr(false);
      mk(JWhile(econd,e, false, namedExpr), min);
    case "for":
      var isEnhanced = false;

      ensure(TPOpen);
      //test if it is enhanced for
      var toRollback = [];
      var level = 0;
      while (true)
      {
        var tk = token();
        toRollback.push(tk);

        switch(tk)
        {
          case TPOpen:
            level++;
          case TPClose:
            if (level-- == 0)
            {
              throw file + ":" + min + " For expression cannot be detected";
            }
          case TSemicolon:
            break;
          case TDoubleDot:
            isEnhanced = true;
            break;
          default:
        }
      }

      for (_ in 0...toRollback.length) add(toRollback.pop());

      if ( isEnhanced ) {
        var t = parseType();
        var varName = id();
        ensure(TDoubleDot);

        var ex = parseExpr(true);

        ensure(TPClose);
        mk(JForEach(t, varName, ex, parseExpr(false), namedExpr), min);
      } else {
        var inits = parseExprList(TSemicolon, true);
        var conds = parseExprList(TSemicolon);
        var incrs = parseExprList(TPClose);
        mk(JFor(inits, conds, incrs, parseExpr(false), namedExpr), min);
      }
    case "break":
      var label = switch( peek() ) {
      case TId(n): token(); n;
      default: null;
      };
      mk(JBreak(label), min);
    case "continue":
      var label = switch( peek() ) {
      case TId(n): token(); n;
      default: null;
      };
      mk(JContinue(label), min);
    case "else": unexpected(TId(kwd));
    case "assert":
      var e1 = parseExpr(true);
      var e2 = null;
      if (opt(TDoubleDot))
      {
        e2 = parseExpr(true);
      }
      mk(JAssert(e1, e2), min);
    case "return":
      mk(JReturn(if( peek() == TSemicolon ) null else parseExpr(true)), min);
    case "new":
        var t = parseType(false);

        if (opt(TBkOpen)) //check if it is array declaration
        {
          add(TBkOpen);
          var lens = [];
          var hasLengthDef = false;

          while (opt(TBkOpen))
          {
            t.t = TArray(t.t);
            if (opt(TBkClose))
            {
              lens.push(null);
            } else {
              lens.push(parseExpr(true));
              ensure(TBkClose);

              hasLengthDef = true;
            }
          }

          var decls = null;
          if (!opt(TBrOpen))
          {
            if (hasLengthDef)
              return mk(JArrayDecl(t, lens, null), min);
            else
              unexpected(token());
          } else {
            decls = [];
            while (!opt(TBrClose))
            {
              decls.push(parseExpr(true));
              opt(TComma);
            }
            mk(JArrayDecl(t, lens, decls), min);
          }
        } else {
          ensure(TPOpen);

          var params = parseExprList(TPClose);

          if (opt(TBrOpen)) //anonymous class
          {
            mk(JNewAnon(t, params, parseFields()), min);
          } else {
            mk(JNew(t, params), min);
          }
        }
    case "throw":
      mk(JThrow( parseExpr(true) ), min);
    case "try":
      var e = parseExpr(false);
      var catches = new Array();
      while( opt(TId("catch")) ) {
        ensure(TPOpen);
        var t = parseType();
        var name = id();

        ensure(TPClose);
        var e = parseExpr(false);
        catches.push( { name : name, t : t, e : e } );
      }

      var finally = null;
      if ( opt(TId("finally")) )
      {
        finally = parseExpr(false);
      }

      mk(JTry(e, catches, finally), min);
    case "switch":
      ensure(TPOpen);
      var e = mk(JParent(parseExpr(true)), min);
      ensure(TPClose);
      var def = null, cl = [];
      ensure(TBrOpen);
      while( !opt(TBrClose) ) {
        if( opt(TId("default")) ) {
          ensure(TDoubleDot);
          def = parseCaseBlock();
        } else {
          ensure(TId("case"));
          var val = parseExpr(true);
          ensure(TDoubleDot);
          var el = parseCaseBlock();
          cl.push( { val : val, el : el } );
        }
      }
      mk(JSwitch(e, cl, def), 2);
    case "class":
      var cl = parseClass([], [], min, [], false);
      mk(JInnerDecl(CDef(cl)), min);
    case "enum":
      var e = parseEnum([], [], min, [], false);
      mk(JInnerDecl(EDef(e)), min);
    case "synchronized":
      ensure(TPOpen);
      var lock = parseExpr(false);
      ensure(TPClose);
      ensure(TBrOpen);

      var block = new Array();
      while( !opt(TBrClose) ) {
        var e = parseFullExpr();
        end();
        block.push(e);
      }

      mk(JSynchronized(lock, block), min);
    case "do":
      var e = parseExpr(false);
      ensure(TId("while"));
      var cond = parseExpr(true);
      mk(JWhile(cond, e, true, namedExpr), min);
    default:
      null;
    }
  }

  function parseCaseBlock() {
    #if debug trace("parseCaseBlock()"); #end
    var el = [];
    while( true ) {
      var tk = peek(false);
      switch( tk ) {
      case TId(id): if( id == "case" || id == "default" ) break;
      case TBrClose: break;
      default:
      }
      el.push(parseExpr(false));
      end();
    }
    return el;
  }

  function parseExprNext( e1 : Expr ) : Expr {
    var min = pos;
    var tk = token();
    #if debug trace("parseExprNext("+tk+")"); #end
    switch( tk ) {
    case TOp(op):
      for( x in unopsSuffix )
        if( x == op ) {
          if( switch(e1.expr) { case JParent(_): true; default: false; } ) {
            add(tk);
            return e1;
          }
          return parseExprNext(mk(JUnop(op,false,e1), min));
        }
      return makeBinop(op,e1,parseExpr(true), min);
    case TDot:
      tk = token();
      var field = null;
      switch(tk) {
      case TId(id):
        field = id;
      default: unexpected(tk);
      }
      return parseExprNext(mk(JField(e1,field), min));
    case TPOpen: //FIXME must implement read params for call
      return parseExprNext(mk(JCall(e1,[],parseExprList(TPClose)), min));
    case TBkOpen:
      var e2 = parseExpr(true);
      tk = token();
      if( tk != TBkClose ) unexpected(tk);
      return parseExprNext(mk(JArray(e1,e2), min));
    case TQuestion:
      var e2 = parseExpr(true);
      tk = token();
      if( tk != TDoubleDot ) unexpected(tk);
      var e3 = parseExpr(true);
      return mk(JTernary(e1, e2, e3), min);
    case TId(s):
      switch( s ) {
      case "instanceof": return mk(JInstanceOf(e1, parseType()), min);
      default:
        add(tk);
        return e1;
      }
    default:
      add(tk);
      return e1;
    }
  }

  function parseExprList( etk, ?full=false ) : Array<Expr> {
    #if debug trace("parseExprList()"); #end

    return cast ignoreComments(
      function() {
      var args = new Array();
      if( opt(etk) )
        return args;
      while( true ) {
        args.push(full ? parseFullExpr() : parseExpr(true));
        var tk = token();
        if (tk == etk) break;

        switch( tk ) {
        case TComma:
        default:
          unexpected(tk);
        }
      }
      return args;
      }
    );

  }

  function readChar() {
    pos++;
    return try input.readByte() catch( e : Dynamic ) 0;
  }

  function readString( until ) {
    #if debug trace("readString()"); #end
    var c;
    var b = new haxe.io.BytesOutput();
    var esc = false;
    var old = line;
    var s = input;
    while( true ) {
      try {
        c = s.readByte();
      } catch( e : Dynamic ) {
        line = old;
        throw EUnterminatedString;
      }
      if( esc ) {
        esc = false;
        switch( c ) {
        case 'n'.code: b.writeByte(10);
        case 'r'.code: b.writeByte(13);
        case 't'.code: b.writeByte(9);
        case "'".code, '"'.code, '\\'.code: b.writeByte(c);
        case '/'.code: b.writeByte(c);
        case "u".code:
          var code;
          try {
            code = s.readString(4);
          } catch( e : Dynamic ) {
            line = old;
            throw EUnterminatedString;
          }
          var k = 0;
          for( i in 0...4 ) {
            k <<= 4;
            var char = code.charCodeAt(i);
            switch( char ) {
            case 48,49,50,51,52,53,54,55,56,57: // 0-9
              k += char - 48;
            case 65,66,67,68,69,70: // A-F
              k += char - 55;
            case 97,98,99,100,101,102: // a-f
              k += char - 87;
            default:
              throw EInvalidChar(char);
            }
          }
          // encode k in UTF8
          if( k <= 0x7F )
            b.writeByte(k);
          else if( k <= 0x7FF ) {
            b.writeByte( 0xC0 | (k >> 6));
            b.writeByte( 0x80 | (k & 63));
          } else {
            b.writeByte( 0xE0 | (k >> 12) );
            b.writeByte( 0x80 | ((k >> 6) & 63) );
            b.writeByte( 0x80 | (k & 63) );
          }
        default:
          b.writeByte(c);
        }
      } else if( c == '\\'.code )
        esc = true;
      else if( c == until )
        break;
      else {
//        if( c == '\n'.code ) line++;
        b.writeByte(c);
      }
    }
    return b.getBytes().toString();
  }

  function peek(ic:Bool=true) : Token {
    var t : Token = null;
    while(true) {
      if( tokens.isEmpty() )
        add(token());
      t = tokens.first();
      switch(t) {
      case TComment(_,_):
        ic ? tokens.pop() : return t;
      default: break;
      }
    }
    return t;
  }

  function id() {
    #if debug trace("id()"); #end
    var t = token();
    while(true) {
      switch(t) {
      case TComment(s,b):
      default: break;
      }
      t = token();
    }
    return switch( t ) {
    case TId(i): #if debug trace("\t-> Got " + i); #end i;
    default: unexpected(t);
    }
  }

  function nextChar() {
    var char = 0;
    if( this.char == 0 )
      return readChar();
    char = this.char;
    this.char = 0;
    return char;
  }

  function token() : Token {
    if( !tokens.isEmpty() ) {
      if(no_comments) {
        while(true) {
          var t = tokens.pop();
          if(t == null) break;
          switch(t) {
          case TComment(_,_):
          default:
            return t;
          }
        }
      } else return tokens.pop();
    }
    var char = nextChar();
    while( true ) {
      switch( char ) {
      case 0: return TEof;
      case ' '.code,'\t'.code:
      case '\n'.code:
        line++;
      case '\r'.code:
        line++;
        char = nextChar();
        if( char == '\n'.code )
          char = nextChar();
        continue;
      case ';'.code: return TSemicolon;
      case '('.code: return TPOpen;
      case ')'.code: return TPClose;
      case ','.code: return TComma;
      case '.'.code, '0'.code, '1'.code, '2'.code, '3'.code, '4'.code, '5'.code, '6'.code, '7'.code, '8'.code, '9'.code:
        var buf = new StringBuf();
        while( char >= '0'.code && char <= '9'.code ) {
          buf.addChar(char);
          char = nextChar();
        }
        switch( char ) {
        case 'x'.code, 'X'.code:
          if( buf.toString() == "0" ) {
            do {
              buf.addChar(char);
              char = nextChar();
            } while ( (char >= '0'.code && char <= '9'.code) || (char >= 'A'.code && char <= 'F'.code) || (char >= 'a'.code && char <= 'f'.code) );
            if (char == 'L'.code)
            {
              this.char = 0;
              return TConst(CLong(buf.toString()));
            } else {
              this.char = char;
              return TConst(CInt(buf.toString()));
            }
          }
        case 'e'.code:
          if( buf.toString() == '.' ) {
            this.char = char;
            return TDot;
          }
          buf.addChar(char);
          char = nextChar();
          if( char == '-'.code ) {
            buf.addChar(char);
            char = nextChar();
          }
          while( char >= '0'.code && char <= '9'.code ) {
            buf.addChar(char);
            char = nextChar();
          }

          if ( char == 'f'.code || char == 'F'.code )
          {
            this.char = 0;
            return TConst(CSingle(buf.toString()));
          }
          this.char = char;
          return TConst(CFloat(buf.toString()));
        case '.'.code:
          do {
            buf.addChar(char);
            char = nextChar();
          } while ( char >= '0'.code && char <= '9'.code );

          var isSingle = false;
          if (char == 'f'.code || char == 'F'.code)
            isSingle = true;
          else
            this.char = char;

          var str = buf.toString();
          if( str.length == 1 ) {
            this.char = char;
            return TDot;
          }
          return TConst(isSingle ? CSingle(str) : CFloat(str));
        case 'L'.code:
          return TConst(CLong(buf.toString()));
        default:
          this.char = char;
          return TConst(CInt(buf.toString()));
        }
      case '{'.code: return TBrOpen;
      case '}'.code: return TBrClose;
      case '['.code: return TBkOpen;
      case ']'.code: return TBkClose;
      case '"'.code, "'".code: return TConst( CString(readString(char)) );
      case '?'.code: return TQuestion;
      case ':'.code:
        char = nextChar();
        if( char == ':'.code )
          return TNs;
        this.char = char;
        return TDoubleDot;
      case '@'.code: return TAt;
      case 0xC2: // UTF8-space
        if( nextChar() != 0xA0 )
          throw EInvalidChar(char);
      case 0xEF: // BOM
        if( nextChar() != 187 || nextChar() != 191 )
          throw EInvalidChar(char);
      default:
        if( ops[char] ) {
          var op = String.fromCharCode(char);
          while( true ) {
            char = nextChar();
            if( !ops[char] ) {
              this.char = char;
              return TOp(op);
            }
            op += String.fromCharCode(char);
            if( op == "//" ) {
              var contents : String = "//";
              try {
                while( char != '\r'.code && char != '\n'.code ) {
                  char = input.readByte();
                  contents += String.fromCharCode(char);
                }
                this.char = char;
              } catch( e : Dynamic ) {
              }
              return no_comments ? token() : TComment(StringTools.trim(contents), false);
            }
            if( op == "/*" ) {
              var old = line;
              var contents : String = "/*";
              try {
                while( true ) {
                  while( char != "*".code ) {
                    if( char == "\n".code ) {
                      line++;
                    }
                    else if( char == "\r".code ) {
                      line++;
                      char = input.readByte();
                      contents += String.fromCharCode(char);
                      if( char == "\n".code ) {
                        char = input.readByte();
                        contents += String.fromCharCode(char);
                      }
                      continue;
                    }
                    char = input.readByte();
                    contents += String.fromCharCode(char);
                  }
                  char = input.readByte();
                  contents += String.fromCharCode(char);
                  if( char == 47 )
                    break;
                }
              } catch( e : Dynamic ) {
                line = old;
                throw EUnterminatedComment;
              }
              if (no_comments)
              {
                if (watchingComments)
                  lastComments.push(TComment(contents, true));
                return token();
              }

              return TComment(contents, true);
            }
            if( op == "!=" ) {
              char = nextChar();
              if(String.fromCharCode(char) != "=")
                this.char = char;
            }
            if( op == "==" ) {
              char = nextChar();
              if(String.fromCharCode(char) != "=")
                this.char = char;
            }
            if( !opPriority.exists(op) ) {
              this.char = char;
              return TOp(op.substr(0, -1));
            }
          }
        }
        if( idents[char] ) {
          var id = String.fromCharCode(char);
          while( true ) {
            char = nextChar();
            if( !idents[char] ) {
              this.char = char;
              return TId(id);
            }
            id += String.fromCharCode(char);
          }
        }
        throw EInvalidChar(char);
      }
      char = nextChar();
    }
    return null;
  }

  function constString( c ) {
    return switch(c) {
    case CInt(v): v;
    case CSingle(f): f + "f";
    case CLong(v): v + "L";
    case CFloat(f): f;
    case CString(s): s; // TODO : escape + quote
    }
  }

  function tokenString( t ) {
    return switch( t ) {
    case TEof: "<eof>";
    case TConst(c): constString(c);
    case TId(s): s;
    case TOp(s): s;
    case TPOpen: "(";
    case TPClose: ")";
    case TBrOpen: "{";
    case TBrClose: "}";
    case TDot: ".";
    case TComma: ",";
    case TSemicolon: ";";
    case TBkOpen: "[";
    case TBkClose: "]";
    case TQuestion: "?";
    case TDoubleDot: ":";
    case TAt: "@";
    case TNs: "::";
    case TComment(s,b): s;
    }
  }

}
