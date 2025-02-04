//          Copyright Brian Schott (Hackerpilot) 2014.
// Distributed under the Boost Software License, Version 1.0.
//    (See accompanying file LICENSE_1_0.txt or copy at
//          http://www.boost.org/LICENSE_1_0.txt)

module dcd.server.dscanner.analysis.ifelsesame;

import std.stdio;
import dparse.ast;
import dparse.lexer;
import dcd.server.dscanner.analysis.base;
import dcd.server.dscanner.analysis.helpers;
import dsymbol.scope_ : Scope;

/**
 * Checks for duplicated code in conditional and logical expressions.
 * $(UL
 * $(LI If statements whose "then" block is the same as the "else" block)
 * $(LI || and && expressions where the left and right are the same)
 * $(LI == expressions where the left and right are the same)
 * )
 */
final class IfElseSameCheck : BaseAnalyzer
{
	alias visit = BaseAnalyzer.visit;

	mixin AnalyzerInfo!"if_else_same_check";

	this(BaseAnalyzerArguments args)
	{
		super(args);
	}

	override void visit(const IfStatement ifStatement)
	{
		if (ifStatement.thenStatement && (ifStatement.thenStatement == ifStatement.elseStatement))
		{
			const(Token)[] tokens = ifStatement.elseStatement.tokens;
			// extend 1 past, so we include the `else` token
			tokens = (tokens.ptr - 1)[0 .. tokens.length + 1];
			addErrorMessage(tokens,
					IF_ELSE_SAME_KEY, "'Else' branch is identical to 'Then' branch.");
		}
		ifStatement.accept(this);
	}

	override void visit(const AssignExpression assignExpression)
	{
		auto e = cast(const AssignExpression) assignExpression.expression;
		if (e !is null && assignExpression.operator == tok!"="
				&& e.ternaryExpression == assignExpression.ternaryExpression)
		{
			addErrorMessage(assignExpression, SELF_ASSIGNMENT_KEY,
					"Left side of assignment operatior is identical to the right side.");
		}
		assignExpression.accept(this);
	}

	override void visit(const AndAndExpression andAndExpression)
	{
		if (andAndExpression.left !is null && andAndExpression.right !is null
				&& andAndExpression.left == andAndExpression.right)
		{
			addErrorMessage(andAndExpression.right,
					LOGIC_OPERATOR_OPERANDS_KEY,
					"Left side of logical and is identical to right side.");
		}
		andAndExpression.accept(this);
	}

	override void visit(const OrOrExpression orOrExpression)
	{
		if (orOrExpression.left !is null && orOrExpression.right !is null
				&& orOrExpression.left == orOrExpression.right)
		{
			addErrorMessage(orOrExpression.right,
					LOGIC_OPERATOR_OPERANDS_KEY,
					"Left side of logical or is identical to right side.");
		}
		orOrExpression.accept(this);
	}

private:

	enum string IF_ELSE_SAME_KEY = "dscanner.bugs.if_else_same";
	enum string SELF_ASSIGNMENT_KEY = "dscanner.bugs.self_assignment";
	enum string LOGIC_OPERATOR_OPERANDS_KEY = "dscanner.bugs.logic_operator_operands";
}

unittest
{
	import dcd.server.dscanner.analysis.config : StaticAnalysisConfig, Check, disabledConfig;

	StaticAnalysisConfig sac = disabledConfig();
	sac.if_else_same_check = Check.enabled;
	assertAnalyzerWarnings(q{
		void testSizeT()
		{
			string person = "unknown";
			if (person == "unknown")
				person = "bobrick"; /* same */
			else
				person = "bobrick"; /* same */ /+
^^^^^^^^^^^^^^^^^^^^^^^ [warn]: 'Else' branch is identical to 'Then' branch. +/
			// note: above ^^^ line spans over multiple lines, so it starts at start of line, since we don't have any way to test this here
			// look at the tests using 1-wide tab width for accurate visuals.

			if (person == "unknown") // ok
				person = "ricky"; // not same
			else
				person = "bobby"; // not same
		}
	}c, sac);

	assertAnalyzerWarnings(q{
		void foo()
		{
			if (auto stuff = call())
		}
	}c, sac);

	stderr.writeln("Unittest for IfElseSameCheck passed.");
}
