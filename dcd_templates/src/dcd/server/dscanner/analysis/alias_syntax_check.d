//          Copyright Brian Schott (Hackerpilot) 2016.
// Distributed under the Boost Software License, Version 1.0.
//    (See accompanying file LICENSE_1_0.txt or copy at
//          http://www.boost.org/LICENSE_1_0.txt)

module dcd.server.dscanner.analysis.alias_syntax_check;

import dparse.ast;
import dparse.lexer;
import dcd.server.dscanner.analysis.base;

/**
 * Checks for uses of the old alias syntax.
 */
final class AliasSyntaxCheck : BaseAnalyzer
{
	alias visit = BaseAnalyzer.visit;

	mixin AnalyzerInfo!"alias_syntax_check";

	this(BaseAnalyzerArguments args)
	{
		super(args);
	}

	override void visit(const AliasDeclaration ad)
	{
		if (ad.declaratorIdentifierList is null)
			return;
		assert(ad.declaratorIdentifierList.identifiers.length > 0,
				"Identifier list length is zero, libdparse has a bug");
		addErrorMessage(ad, KEY,
				"Prefer the new \"'alias' identifier '=' type ';'\" syntax"
				~ " to the  old \"'alias' type identifier ';'\" syntax.");
	}

private:
	enum KEY = "dscanner.style.alias_syntax";
}

unittest
{
	import dcd.server.dscanner.analysis.helpers : assertAnalyzerWarnings;
	import dcd.server.dscanner.analysis.config : StaticAnalysisConfig, Check, disabledConfig;
	import std.stdio : stderr;

	StaticAnalysisConfig sac = disabledConfig();
	sac.alias_syntax_check = Check.enabled;
	assertAnalyzerWarnings(q{
		alias int abcde; /+
		^^^^^^^^^^^^^^^^ [warn]: Prefer the new "'alias' identifier '=' type ';'" syntax to the  old "'alias' type identifier ';'" syntax.+/
		alias abcde = int;
	}c, sac);

	stderr.writeln("Unittest for AliasSyntaxCheck passed.");
}
