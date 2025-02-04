//          Copyright Brian Schott (Hackerpilot) 2014.
// Distributed under the Boost Software License, Version 1.0.
//    (See accompanying file LICENSE_1_0.txt or copy at
//          http://www.boost.org/LICENSE_1_0.txt)

module dcd.server.dscanner.analysis.length_subtraction;

import std.stdio;

import dparse.ast;
import dparse.lexer;
import dcd.server.dscanner.analysis.base;
import dcd.server.dscanner.analysis.helpers;
import dsymbol.scope_;

/**
 * Checks for subtraction from a .length property. This is usually a bug.
 */
final class LengthSubtractionCheck : BaseAnalyzer
{
	private enum string KEY = "dscanner.suspicious.length_subtraction";

	alias visit = BaseAnalyzer.visit;

	mixin AnalyzerInfo!"length_subtraction_check";

	this(BaseAnalyzerArguments args)
	{
		super(args);
	}

	override void visit(const AddExpression addExpression)
	{
		if (addExpression.operator == tok!"-")
		{
			const UnaryExpression l = cast(const UnaryExpression) addExpression.left;
			const UnaryExpression r = cast(const UnaryExpression) addExpression.right;
			if (l is null || r is null)
				goto end;
			if (r.primaryExpression is null || r.primaryExpression.primary.type != tok!"intLiteral")
				goto end;
			if (l.identifierOrTemplateInstance is null
					|| l.identifierOrTemplateInstance.identifier.text != "length")
				goto end;
			addErrorMessage(addExpression, KEY,
					"Avoid subtracting from '.length' as it may be unsigned.",
					[
						AutoFix.insertionBefore(l.tokens[0], "cast(ptrdiff_t) ", "Cast to ptrdiff_t")
					]);
		}
	end:
		addExpression.accept(this);
	}
}

unittest
{
	import dcd.server.dscanner.analysis.config : StaticAnalysisConfig, Check, disabledConfig;

	StaticAnalysisConfig sac = disabledConfig();
	sac.length_subtraction_check = Check.enabled;
	assertAnalyzerWarnings(q{
		void testSizeT()
		{
			if (i < a.length - 1) /+
			        ^^^^^^^^^^^^ [warn]: Avoid subtracting from '.length' as it may be unsigned. +/
				writeln("something");
		}
	}c, sac);

	assertAutoFix(q{
		void testSizeT()
		{
			if (i < a.length - 1) // fix
				writeln("something");
		}
	}c, q{
		void testSizeT()
		{
			if (i < cast(ptrdiff_t) a.length - 1) // fix
				writeln("something");
		}
	}c, sac);
	stderr.writeln("Unittest for IfElseSameCheck passed.");
}
