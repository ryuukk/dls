/**
 * This file is part of DCD, a development tool for the D programming language.
 * Copyright (C) 2014 Brian Schott
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program.  If not, see <http://www.gnu.org/licenses/>.
 */

module dsymbol.conversion.third;

import dsymbol.modulecache;
import dsymbol.scope_;
import dsymbol.semantic;
import dsymbol.symbol;
import dsymbol.string_interning;
import dsymbol.deferred;

import containers.hashset;
import std.stdio;

/**
 * Used to resolve the type of remaining symbols that were left out due to modules being parsed from other modules that depend on each other (public imports)
 * It will start from the scope of interest at the cursorPosition, and it'll traverse the scope from bottom to top and check if the symbol's type is know
 * If it is, then it'll set its type
 * If the symbol is not found, then it'll do nothing 
 */
void thirdPass(SemanticSymbol* root, Scope* mscope, ref ModuleCache cache, size_t cursorPosition)
{
	auto desired = mscope.getScopeByCursor(cursorPosition);
	tryResolve(desired, cache);

	// Check if there are any left out symbols
	// Check issue 717 and test tc717
	checkMissingTypes(root, mscope, cache);
}

void checkMissingTypes(SemanticSymbol* currentSymbol, Scope* moduleScope, ref ModuleCache cache)
{
	import dsymbol.conversion.second;
	import dsymbol.type_lookup;

	with (CompletionKind) switch (currentSymbol.acSymbol.kind)
	{
	case withSymbol:
	case variableName:
	case memberVariableName:
	case functionName:
	case ufcsName:
	case aliasName:
		if (currentSymbol.acSymbol.type is null)
		{
			if (currentSymbol.typeLookups.length == 0)
				break;
			auto lookup = currentSymbol.typeLookups.front;

            if (lookup.ctx.root)
            {
                import std.stdio;
                //writeln(">>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>> ", currentSymbol.acSymbol.name," ", lookup.ctx.calltip);
            }

			if (lookup.kind == TypeLookupKind.varOrFunType)
				resolveTypeFromType(currentSymbol.acSymbol, lookup, moduleScope, cache, null);
			else if (lookup.kind == TypeLookupKind.initializer)
				resolveTypeFromInitializer(currentSymbol.acSymbol, lookup, moduleScope, cache);
		}
		break;
		default:
		break;
	}

	foreach (child; currentSymbol.children)
		checkMissingTypes(child, moduleScope, cache);
}

/**
 * Used to resolve missing symbols within a scope
 */
void tryResolve(Scope* sc, ref ModuleCache cache)
{
    if (sc is null) return;
    auto symbols = sc.symbols;
    foreach (item; symbols)
    {
        DSymbol* target = item.type;

        if (target !is null)
        {
            HashSet!size_t visited;
            foreach (part; target.opSlice())
            {
                resolvePart(part, sc, cache, visited);
            }
        }
    }
    if (sc.parent !is null) tryResolve(sc.parent, cache);
}

void resolvePart(DSymbol* part, Scope* sc, ref ModuleCache cache, ref HashSet!size_t visited)
{
    if (visited.contains(cast(size_t) part))
        return;
    visited.insert(cast(size_t) part);

    // no type but a typeSymbolName, let's resolve its type
    if (part.type is null && part.typeSymbolName !is null)
    {
        import std.string: indexOf;
        auto typeName = part.typeSymbolName;

        // check if it is available in the scope
        // otherwise grab its module symbol to check if it's publickly available
        auto result = sc.getSymbolsAtGlobalScope(istring(typeName));
        if (result.length > 0)
        {
            part.type = result[0];
            return;
        }
        else
        {
            if (part.symbolFile == "stdin") return;
            if (part.symbolFile.length == 0) return; // custom object.d stuff
            auto moduleSymbol = cache.getModuleSymbol(part.symbolFile);
            auto first = moduleSymbol.getFirstPartNamed(istring(typeName));
            if (first !is null)
            {
                part.type = first;
                return;
            }
            else
            {
                // type couldn't be found, that's stuff like templates
                // now we could try to resolve them!
                // warning("can't resolve: ", part.name, " callTip: ", typeName);
                return;
            }
        }
    }

    if (part.type !is null)
    {
        import std;
        //writeln("check: ", part.type.name, " ", part.type.type, " ", part.type.qualifier, " ", part.type.kind);
        foreach (typePart; part.type.opSlice())
        {
            resolvePart(typePart, sc, cache, visited);
        }
    }
}