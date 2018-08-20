// Copyright (c) 2013, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

part of uri_template;

/**
 * Parsable templates have the following restrictions over expandable
 * templates:
 *
 *  * URI components must come in order: scheme, host, path, query, fragment,
 *    and there can only be one of each.
 *  * Path expressions can only contain one variable, and multiple expressions
 *    must be separated by a literal
 *  * Only the following operators are supported: default, +, #, ?, &
 *  * default and + operators are not allowed in query or fragment components
 *  * Queries can only use the ? or & operator. The ? operator can only be used
 *    once.
 *  * Fragments can only use the # operator
 */
class UriParser {
  final UriTemplate template;

  RegExp _pathRegex;
  List<String> _pathVariables;
  Map<String, String> _queryVariables;
  RegExp _fragmentRegex;
  List<String> _fragmentVariables;

  // TODO(justinfagnani): remove
  RegExp get fragmentRegex => _fragmentRegex;
  RegExp get pathRegex => _pathRegex;

  UriParser(UriTemplate this.template) {
    if (template == null) throw new ArgumentError("null template A");
    var compiler = new _Compiler(template);
    _pathRegex = compiler.pathRegex;
    _pathVariables = compiler.pathVariables;
    _queryVariables = compiler.queryVariables;
    _fragmentRegex = compiler.fragmentRegex;
    _fragmentVariables = compiler.fragmentVariables;
  }

  /**
   * Parses [uriString] returning the parameter values in a map keyed by the
   * variable names in the template.
   */
  Map<String, String> parse(Uri uri) {
    var parameters = <String,String>{};

    if (_pathVariables.isNotEmpty) {
      var match = _pathRegex.firstMatch(uri.path);

      if (match == null) {
        throw new ParseException('$template does not match $uri');
      }
      int i = 1;
      for (var param in _pathVariables) {
        parameters[param] = match.group(i++);
      }
    }

    if (_queryVariables.isNotEmpty) {
      for (var key in _queryVariables.keys) {
        if (_queryVariables[key] == null) {
          parameters[key] = uri.queryParameters[key];
        }
      }
    }

    if (_fragmentRegex != null) {
      var match = _fragmentRegex.firstMatch(uri.fragment);
      if (match == null) {
        throw new ParseException('$template does not match $uri');
      }
      int i = 1;
      for (var param in _fragmentVariables) {
        parameters[param] = match.group(i++);
      }
    }
    return parameters;
  }

  bool matches(Uri uri) {
    if (_pathRegex != null && !matchesFull(_pathRegex, uri.path)) return false;

    for (var key in _queryVariables.keys) {
      var value = _queryVariables[key];
      if (value == null && !uri.queryParameters.containsKey(key)) {
        return false;
      }
      if (value != null && uri.queryParameters[key] != value) {
        return false;
      }
    }

    if (_fragmentRegex != null &&
        (uri.fragment.isEmpty || !matchesFull(_fragmentRegex, uri.fragment))) {
      return false;
    }
    return true;
  }

  UriMatch parsePrefix(Uri uri) {
    var parameters = <String,String>{};
    var restUriBuilder = new UriBuilder();
    bool matches = true;

    if (_pathRegex != null) {
      var match = _pathRegex.firstMatch(uri.path);
      if (match == null) {
        matches = false;
      } else {
        int i = 1;
        for (var param in _pathVariables) {
          parameters[param] = match.group(i++);
        }
        restUriBuilder.path = uri.path.substring(match.end);
      }
    } else {
      restUriBuilder.path = uri.path;
    }

    if (_queryVariables.isNotEmpty) {
      // TODO(justinfagnani): remove matched parameters?
      restUriBuilder.queryParameters.addAll(uri.queryParameters);
      for (var key in _queryVariables.keys) {
        var value = _queryVariables[key];
        if (value == null) {
          if (!uri.queryParameters.containsKey(key)) {
            matches = false;
          } else {
            parameters[key] = uri.queryParameters[key];
          }
        } else if (uri.queryParameters[key] != value) {
          matches = false;
        }
      }
    }

    if (_fragmentRegex != null) {
      var match = _fragmentRegex.firstMatch(uri.fragment);
      if (match == null) {
        matches = false;
      } else {
        int i = 1;
        for (var param in _fragmentVariables) {
          parameters[param] = match.group(i++);
        }
        restUriBuilder.fragment = uri.fragment.substring(match.end);
      }
    }
    return new UriMatch(matches, parameters, restUriBuilder.build());
  }
}

class UriMatch {
  final bool matches;
  final Map<String, String> parameters;
  final Uri rest;

  UriMatch(this.matches, this.parameters, this.rest);

  String toString() => 'UriMatch(matches: $matches rest: $rest)';
}

/*
 * Compiles a template into a set of regexes and variable names to be used for
 * parsing URIs.
 *
 * How the compiler works:
 *
 * Processing starts off in 'path' mode, then optionaly switches to 'query'
 * mode, and then to 'fragment' mode if those sections are encountered in the
 * template.
 *
 * The template is first split into literal and expression parts. Then each part
 * is processed. If the part is a literal, it's checked for URI query and
 * fragment parts, and if it contains one processing is handed off to the
 * appropriate _compileX method. If the part is a Match, then it's an expression
 * and the operator is checked, if it's a '?' or '#' processing is also handed
 * over to the next _compileX method.
 */
class _Compiler {
  final Iterator _parts;

  RegExp pathRegex;
  final List<String> pathVariables = [];

  final Map<String, String> queryVariables = {};

  RegExp fragmentRegex;
  final List<String> fragmentVariables = [];

  _Compiler(UriTemplate template) : _parts = template._parts.iterator {
    _compilePath();
  }

  _compilePath() {
    StringBuffer pathBuffer = new StringBuffer();

    while (_parts.moveNext()) {
      var part = _parts.current;
      if (part is String) {
        var subparts = _splitLiteral(part);
        for (int i = 0; i < subparts.length; i++) {
          var subpart = subparts[i];
          if (subpart is String) {
            pathBuffer.write('(?:${escapeRegex(subpart)})');
          } else if ((subpart as Match).group(1) == '?') {
            _compileQuery(prevParts: subparts.sublist(i + 1));
            break;
          } else if ((subpart as Match).group(1) == '#') {
            _compileFragment(prevParts: subparts.sublist(i + 1));
            break;
          }
        }
      } else {
        Match match = part;
        var expr = match.group(3);
        var op = match.group(2);
        if (op == '') {
          pathBuffer.write(expr.split(',').map((varspec) {
            // store the variable name
            pathVariables.add(_varspecRegex.firstMatch(varspec).group(1));
            return r'((?:\w|%)+)';
          }).join(','));
        } else if (op == '+') {
          pathBuffer.write(expr.split(',').map((varspec) {
            // store the variable name
            pathVariables.add(_varspecRegex.firstMatch(varspec).group(1));
            // The + operator allows reserved chars, except ?, #, [,  and ]
            // which cannot appear in URI paths
            return r"((?:\w|[:/@!$&'()*+,;=])+)";
          }).join(','));
        } else if (op == '?' || op == '&') {
          _compileQuery(match: match);
        } else if (op == '#') {
          _compileFragment(match: match);
        }
      }
    }
    if (pathBuffer.isNotEmpty) {
      pathRegex = new RegExp(pathBuffer.toString());
    }
  }

  _compileQuery({Match match, List prevParts}) {
    handleExpressionMatch(Match match) {
      var expr = match.group(3);
      for (var q in expr.split(',')) {
        // TODO: handle modifiers
        var key = _varspecRegex.firstMatch(q).group(1);
        queryVariables[key] = null;
      }
    }

    handleLiteralParts(List literalParts) {
      for (int i = 0; i < literalParts.length; i++) {
        var subpart = literalParts[i];
        if (subpart is String) {
          queryVariables.addAll(_parseMap(subpart, '&'));
        }
        else if ((subpart as Match).group(1) == '?') {
          throw new ParseException('multiple queries');
        } else if ((subpart as Match).group(1) == '#') {
          return _compileFragment(prevParts: literalParts.sublist(i + 1));
        }
      }
    }

    if (match != null) {
      handleExpressionMatch(match);
    }
    if (prevParts != null) {
      handleLiteralParts(prevParts);
    }
    while (_parts.moveNext()) {
      var part = _parts.current;
      if (part is String) {
        handleLiteralParts(_splitLiteral(part));
      } else {
        Match match = part;
        var op = match.group(2);
        if (op == '&') {
          // add a query variable
          handleExpressionMatch(match);
        } else if (op == '?') {
          throw new ParseException('multiple queries');
        } else if (op == '#') {
          return _compileFragment(match: match);
        } else {
          // TODO: add a query variable if the expr is in a value position?
          throw new ParseException('invalid operator for query part');
        }
      }
    }
  }

  _compileFragment({Match match, List prevParts}) {
    var fragmentBuffer = new StringBuffer();

    handleExpressionMatch(Match match) {
      var expr = match.group(3);
      fragmentBuffer.write(expr.split(',').map((varspec) {
        // store the variable name
        fragmentVariables.add(_varspecRegex.firstMatch(varspec).group(1));
        return r'((?:\w|%)*)';
      }).join(','));
    }

    if (match != null) {
      handleExpressionMatch(match);
    }

    if (prevParts != null) {
      for (int i = 0; i < prevParts.length; i++) {
        var subpart = prevParts[i];
        if (subpart is String) {
          fragmentBuffer.write('(?:${escapeRegex(subpart)})');
        } else if ((subpart as Match).group(1) == '?') {
          throw new ParseException('?');
        } else if ((subpart as Match).group(1) == '#') {
          throw new ParseException('#');
        }
      }
    }
    while (_parts.moveNext()) {
      var part = _parts.current;
      if (part is String) {
        fragmentBuffer.write('(?:${escapeRegex(part)})');
      } else {
        Match match = part;
        var op = match.group(2);
        if (op == '#') {
          handleExpressionMatch(match);
        } else {
          // TODO: add a query variable if the expr is in a value position?
          throw new ParseException('invalid operator for fragment part');
        }
      }
    }
    if (fragmentBuffer.isNotEmpty) {
      fragmentRegex = new RegExp(fragmentBuffer.toString());
    }
  }

}

Map<String, String> _parseMap(String s, String separator) {
  var map = <String,String>{};
  var kvPairs = s.split(separator);
  for (int i = 0; i < kvPairs.length; i++) {
    String kvPair = kvPairs[i];
    var eqIndex = kvPair.indexOf('=');
    if (eqIndex > -1) {
      var key = kvPair.substring(0, eqIndex);
      var value = '';
      // handle key1=,,key2=x
      if (eqIndex == kvPair.length - 1) {
        if (i < kvPairs.length - 1 && kvPairs[i+1] == '') {
          value = ',';
        }
        // else value = '';
      } else {
        value = kvPair.substring(eqIndex + 1);
      }
      map[key] = value;
    }
  }
  return map;
}

List _splitLiteral(String literal) {
  var subparts = [];
  literal.splitMapJoin(_fragOrQueryRegex,
      onMatch: (m){
          subparts.add(m);
          return '';
          },
      onNonMatch: (s){
          subparts.add(s);
          return '';
          }
    );
  return subparts;
}
