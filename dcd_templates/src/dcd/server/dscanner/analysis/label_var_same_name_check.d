// Distributed under the Boost Software License, Version 1.0.
//    (See accompanying file LICENSE_1_0.txt or copy at
//          http://www.boost.org/LICENSE_1_0.txt)

module dcd.server.dscanner.analysis.label_var_same_name_check;

import dparse.ast;
import dparse.lexer;
import dsymbol.scope_ : Scope;
import dcd.server.dscanner.analysis.base;
import dcd.server.dscanner.analysis.helpers;

/**
 * Checks for labels and variables that have the same name.
 */
final class LabelVarNameCheck : ScopedBaseAnalyzer
{
	mixin AnalyzerInfo!"label_var_same_name_check";

	this(BaseAnalyzerArguments args)
	{
		super(args);
	}

	mixin AggregateVisit!ClassDeclaration;
	mixin AggregateVisit!StructDeclaration;
	mixin AggregateVisit!InterfaceDeclaration;
	mixin AggregateVisit!UnionDeclaration;

	override void visit(const VariableDeclaration var)
	{
		foreach (dec; var.declarators)
			duplicateCheck(dec.name, false, conditionalDepth > 0);
	}

	override void visit(const LabeledStatement labeledStatement)
	{
		duplicateCheck(labeledStatement.identifier, true, conditionalDepth > 0);
		if (labeledStatement.declarationOrStatement !is null)
			labeledStatement.declarationOrStatement.accept(this);
	}

	override void visit(const ConditionalDeclaration condition)
	{
		if (condition.falseDeclarations.length > 0)
			++conditionalDepth;
		condition.accept(this);
		if (condition.falseDeclarations.length > 0)
			--conditionalDepth;
	}

	override void visit(const VersionCondition condition)
	{
		++conditionalDepth;
		condition.accept(this);
		--conditionalDepth;
	}

	alias visit = ScopedBaseAnalyzer.visit;

private:

	enum string KEY = "dscanner.suspicious.label_var_same_name";

	Thing[string][] stack;

	template AggregateVisit(NodeType)
	{
		override void visit(const NodeType n)
		{
			pushAggregateName(n.name);
			n.accept(this);
			popAggregateName();
		}
	}

	void duplicateCheck(const Token name, bool fromLabel, bool isConditional)
	{
		import std.conv : to;
		import std.range : retro;

		size_t i;
		foreach (s; retro(stack))
		{
			string fqn = parentAggregateText ~ name.text;
			const(Thing)* thing = fqn in s;
			if (thing is null)
				currentScope[fqn] = Thing(fqn, name.line, name.column, !fromLabel /+, isConditional+/ );
			else if (i != 0 || !isConditional)
			{
				immutable thisKind = fromLabel ? "Label" : "Variable";
				immutable otherKind = thing.isVar ? "variable" : "label";
				addErrorMessage(name, KEY,
						thisKind ~ " \"" ~ fqn ~ "\" has the same name as a "
						~ otherKind ~ " defined on line " ~ to!string(thing.line) ~ ".");
			}
			++i;
		}
	}

	static struct Thing
	{
		string name;
		size_t line;
		size_t column;
		bool isVar;
		//bool isConditional;
	}

	ref currentScope() @property
	{
		return stack[$ - 1];
	}

	protected override void pushScope()
	{
		stack.length++;
	}

	protected override void popScope()
	{
		stack.length--;
	}

	int conditionalDepth;

	void pushAggregateName(Token name)
	{
		parentAggregates ~= name;
		updateAggregateText();
	}

	void popAggregateName()
	{
		parentAggregates.length -= 1;
		updateAggregateText();
	}

	void updateAggregateText()
	{
		import std.algorithm : map;
		import std.array : join;

		if (parentAggregates.length)
			parentAggregateText = parentAggregates.map!(a => a.text).join(".") ~ ".";
		else
			parentAggregateText = "";
	}

	Token[] parentAggregates;
	string parentAggregateText;
}

unittest
{
	import dcd.server.dscanner.analysis.config : StaticAnalysisConfig, Check, disabledConfig;
	import std.stdio : stderr;

	StaticAnalysisConfig sac = disabledConfig();
	sac.label_var_same_name_check = Check.enabled;
	assertAnalyzerWarnings(q{
unittest
{
blah:
	int blah; /+
	    ^^^^ [warn]: Variable "blah" has the same name as a label defined on line 4. +/
}
int blah;
unittest
{
	static if (stuff)
		int a;
	int a; /+
	    ^ [warn]: Variable "a" has the same name as a variable defined on line 12. +/
}

unittest
{
	static if (stuff)
		int a = 10;
	else
		int a = 20;
}

unittest
{
	static if (stuff)
		int a = 10;
	else
		int a = 20;
	int a; /+
	    ^ [warn]: Variable "a" has the same name as a variable defined on line 30. +/
}
template T(stuff)
{
	int b;
}

void main(string[] args)
{
	for (int a = 0; a < 10; a++)
		things(a);

	for (int a = 0; a < 10; a++)
		things(a);
	int b;
}

unittest
{
	version (Windows)
		int c = 10;
	else
		int c = 20;
	int c; /+
	    ^ [warn]: Variable "c" has the same name as a variable defined on line 54. +/
}

unittest
{
	version(LittleEndian) { enum string NAME = "UTF-16LE"; }
	else version(BigEndian)    { enum string NAME = "UTF-16BE"; }
}

unittest
{
	int a;
	struct A {int a;}
}

unittest
{
	int a;
	struct A { struct A {int a;}}
}

unittest
{
	int a;
	class A { class A {int a;}}
}

unittest
{
	int a;
	interface A { interface A {int a;}}
}

unittest
{
	interface A
	{
		int a;
		int a; /+
		    ^ [warn]: Variable "A.a" has the same name as a variable defined on line 93. +/
	}
}

unittest
{
	int aa;
	struct a { int a; }
}

unittest
{
	switch (1) {
	case 1:
		int x, c1;
		break;
	case 2:
		int x, c2;
		break;
	default:
		int x, def;
		break;
	}
}

}c, sac);
	stderr.writeln("Unittest for LabelVarNameCheck passed.");
}
