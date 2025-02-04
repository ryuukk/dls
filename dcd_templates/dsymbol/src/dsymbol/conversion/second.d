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

module dsymbol.conversion.second;

import dsymbol.semantic;
import dsymbol.string_interning;
import dsymbol.symbol;
import dsymbol.scope_;
import dsymbol.builtin.names;
import dsymbol.builtin.symbols;
import dsymbol.type_lookup;
import dsymbol.deferred;
import dsymbol.import_;
import dsymbol.modulecache;
import std.experimental.allocator;
import std.experimental.allocator.gc_allocator : GCAllocator;
import std.experimental.logger;
import dparse.ast;
import dparse.lexer;
import std.algorithm : filter;
import std.range;
import io = std.stdio;

void DBG(F, A...)(F f, A args)
{
    //debug io.writeln(f, args);
}
package void writeln(F, A...)(F f, A args)
{
    //debug io.writeln(f, args);
}

package void write(F, A...)(F f, A args)
{
    //debug io.write(f, args);
}

void print_tab(int index)
{
    //debug index +=1;
    //debug enum C = 4;
    //debug for(int i =0; i < index*4; i++) io.write(" ");
}


void secondPass(SemanticSymbol* rootModule, SemanticSymbol* currentSymbol, Scope* moduleScope, ref ModuleCache cache)
{
    writeln("-- second pass: begin");
	with (CompletionKind) final switch (currentSymbol.acSymbol.kind)
	{
	case className:
	case interfaceName:
		resolveInheritance(currentSymbol.acSymbol, currentSymbol.typeLookups,
			moduleScope, cache);
		break;
	case withSymbol:
	case variableName:
	case memberVariableName:
	case functionName:
	case ufcsName:
	case aliasName:
		// type may not be null in the case of a renamed import
		if (currentSymbol.acSymbol.type is null)
		{
			resolveType(currentSymbol.acSymbol, currentSymbol.typeLookups,
				moduleScope, cache);
		}

		if (currentSymbol.acSymbol.type && currentSymbol.typeLookups.length > 0)
		{
			foreach(lookup; currentSymbol.typeLookups[]) {

				writeln("lookup: ", lookup.breadcrumbs[], " ctx: ", lookup.ctx.root);
				if (lookup.ctx.root)
				{
					auto type = currentSymbol.acSymbol.type;
					if (type.kind == structName || type.kind == className || type.kind == functionName || type.kind)
					{
						if (lookup.ctx.root.args.length > 0)
						{
							DSymbol*[string] mapping;
							int depth;
							resolveTemplate(currentSymbol.acSymbol, type, lookup, lookup.ctx.root, moduleScope, cache, depth, mapping);
							break;
						}
					}
				}
			}
		}
		break;
	case importSymbol:
		if (currentSymbol.acSymbol.type is null)
			resolveImport(rootModule.acSymbol, currentSymbol.acSymbol, currentSymbol.typeLookups, cache);

		//warning("root: ", rootModule.acSymbol.symbolFile, " >import> ", currentSymbol.acSymbol.symbolFile, " public:", currentSymbol.acSymbol.skipOver == false);

		//auto importedFromSym = GCAllocator.instance.make!DSymbol("*public_imported*", CompletionKind.dummy, rootModule.acSymbol);
		//currentSymbol.acSymbol.addChild(importedFromSym, true);

		break;
	case variadicTmpParam:
		currentSymbol.acSymbol.type = variadicTmpParamSymbol;
		break;
	case typeTmpParam:
		currentSymbol.acSymbol.type = typeTmpParamSymbol;
		break;
	case structName:
	case unionName:
	case enumName:
	case keyword:
	case enumMember:
	case packageName:
	case moduleName:
	case dummy:
	case templateName:
	case mixinTemplateName:
		break;
	}

	// let's be methodic about the way we traverse symbols
	// so that childs have access to resolved symbols
	// functions should be last, because inside, there might be symbols that references
	// code from the parent not yet resolved (templates)
    if (currentSymbol && currentSymbol.children.length)
	foreach (child; currentSymbol.children)
		if (child.acSymbol.kind != CompletionKind.variableName && child.acSymbol.kind != CompletionKind.functionName)
			secondPass(rootModule, child, moduleScope, cache);

	foreach (child; currentSymbol.children)
		if (child.acSymbol.kind == CompletionKind.variableName)
			secondPass(rootModule, child, moduleScope, cache);

	foreach (child; currentSymbol.children)
		if (child.acSymbol.kind == CompletionKind.functionName)
			secondPass(rootModule, child, moduleScope, cache);


	// Alias this and mixin templates are resolved after child nodes are
	// resolved so that the correct symbol information will be available.
	with (CompletionKind) switch (currentSymbol.acSymbol.kind)
	{
	case className:
	case interfaceName:
	case structName:
	case unionName:
		resolveAliasThis(currentSymbol.acSymbol, currentSymbol.typeLookups, moduleScope, cache);
		resolveMixinTemplates(currentSymbol.acSymbol, currentSymbol.typeLookups,
			moduleScope, cache);
		break;
	default:
		break;
	}

    writeln("-- second pass: end");
    writeln("");
    writeln("");
    writeln("");
    writeln("");
}
/**
 * Extract the return type from the callTip of a function symbol
 */
string extractReturnType(string callTip)
{
	import std.string: indexOf;

	auto spaceIndex = callTip.indexOf(" ");
	if (spaceIndex <= 0) return "";

	auto retPart = callTip[0 .. spaceIndex];
	auto returnTypeConst = retPart.length > 6 ? retPart[0 .. 6] == "const(" : false;
	auto returnTypeInout = retPart.length > 6 ? retPart[0 .. 6] == "inout(" : false;
	if (returnTypeConst || returnTypeInout)
	{
		retPart = retPart[retPart.indexOf("(") + 1 .. $];
		retPart = retPart[0 .. retPart.indexOf(")")];
	}
	auto returnTypePtr = retPart[$-1] == '*';
	auto returnTypeArr = retPart[$-1] == ']';
	if (returnTypePtr)
	{
		retPart = retPart[0 .. $-1];
	}
	return retPart;
}

/**
 * Copy a Type symbol with templates arguments
 * Returns: Copy of Type symbol
 */
DSymbol* createTypeWithTemplateArgs(DSymbol* type, TypeLookup* lookup, VariableContext.TypeInstance* ti, ref ModuleCache cache, Scope* moduleScope, ref int depth, DSymbol*[string] m)
{
	assert(type);
	DSymbol* newType = GCAllocator.instance.make!DSymbol("dummy", CompletionKind.dummy, null);
	newType.name = ti ? istring(ti.calltip) : istring(lookup.ctx.calltip);


    print_tab(depth); write("newType.name ", newType.name,"\n");
    print_tab(depth); write("  type:          ", type.name,"\n");
    print_tab(depth); write("  type.ct:       ", type.callTip,"\n");
    print_tab(depth); write("  ti.calltip:    ", ti.calltip,"\n");
    print_tab(depth); write("  lookup.calltip:", lookup.ctx.calltip,"\n");

	// TODO: need to set the name in first.d
    bool needCT = false;
	if (newType.name.length == 0)
	{
        needCT = true;
        print_tab(depth); write("newType.name == 0 ", newType.callTip,"\n");
        newType.name = type.name;
    }

	print_tab(depth); write(">>", type.name, " > ", newType.name, " ::", ti," args: ", ti.args.length, " ct: ", ti.calltip);
	writeln("");

	newType.kind = type.kind;
	newType.qualifier = type.qualifier;
	newType.protection = type.protection;
	newType.symbolFile = type.symbolFile;
    newType.location = type.location;
    newType.location_end = type.location_end;
	newType.doc = type.doc;
	newType.type = type.type;
	DSymbol*[string] mapping;

    DBG("type: ", type.name, " ct: ", type.callTip, " kind: ", type.kind);
	int count = 0;
	if (ti.args.length > 0)
	{
        // we need to sort the symbols so mapping order matches
        // TODO: sort it in first.d directly
        // TODO: remove this shit
        DSymbol*[8] allT;
        int TC = 0;
		foreach(part; type.opSlice())
            if (part.kind == CompletionKind.typeTmpParam)
            {
                allT[TC] = part;
                TC++;
            }
        auto slice = allT[0 .. TC];
        import std.algorithm.sorting : sort;
        sort!((a, b) => a.location < b.location)(slice);

        foreach(part; slice)
		{
			if (part.kind == CompletionKind.typeTmpParam)
			{
                DBG(" index: ", part.location);
				scope(exit) count++;
				if (count >= ti.args.length)
				{
					//print_tab(depth);writeln("too many T for args available, investigate");
					continue;
				}
				auto key = part.name;

				//print_tab(depth);writeln("> check template arg: ", key,"\n");
				//print_tab(depth);io.write("chain: ");
				//foreach(i, crumb; ti.args[count].chain)
				//{
				//	io.write(crumb, ", ");
				//}
				//writeln("");

				DSymbol* first;
				bool isBuiltin;
				foreach(i, crumb; ti.args[count].chain)
				{
					auto argName = crumb;


                    print_tab(depth);writeln("> crumb: ", argName,"\n");
					if (i == 0)
					{
						if (m && key in m)
						{
							argName = m[key].name;
						}

						// check if that's a built in type
						// if it is, then use it and skip the type creation step
						foreach(builtin; builtinSymbols)
						{
							if (builtin.name == crumb)
							{
								first = builtin;
								isBuiltin = true;
								break;
							}
						}
						auto result = moduleScope.getSymbolsAtGlobalScope(istring(argName));
						if (result.length == 0)
						{
							//print_tab(depth);writeln("modulescope: symbol not found: ", argName);
							break;
						}
						first = result[0];
						//print_tab(depth);writeln("modulescope: symbol found: ", argName, " -> ", first.name);
					}
					else
					{
						first = first.getFirstPartNamed(istring(argName));
						if (first)
						{
							//print_tab(depth);writeln("symbol found: ", argName, " -> ", first.name);
						}
						else
						{
								//print_tab(depth);writeln("symbol not found: ", argName);
						}
					}
				}

				if (first is null)
					continue;

				//print_tab(depth);writeln(">> ok");
				auto ca = ti.args[count];
				if (ca.chain.length > 0)
				{
					int indepth = depth + 1;
					auto stomap = isBuiltin ? first : createTypeWithTemplateArgs(first, lookup, ca, cache, moduleScope, indepth, null);
					mapping[key] = stomap;

					print_tab(depth);writeln("mapping[",key,"] -> ", stomap.name, " builtin: ", isBuiltin);
				}
			}
			else
			{
				//writeln(">>>>>>>>>>>>>>> what: ", part.kind," ", part.name);
			}
		}
	}

	// HACK: to support functions with template arguments that return a generic type
	// first.d in processParameters only store the function's return type in the callTip
	// maybe it's time to properly handle it by creating a proper symbol, so we can have
	// proper support for functions that return complex types such as templates

    foreach(k, v; mapping)
        DBG(" m: ", k,":",v.name);

    //foreach(part; type.opSlice())
    //{
    //    DBG(" p: ", part.name, " -> ", (part.type ? part.type.name : ""));

    //}



	if (type.kind == CompletionKind.functionName)
	{
		auto callTip = type.callTip;
		if (callTip && callTip.length > 1)
		{
			auto retType = extractReturnType(callTip);
            DBG("fn ", callTip, " ret: ", retType);
			if (retType in mapping)
			{
				auto result = mapping[retType];
				newType.ownType = result.kind == CompletionKind.keyword ? false : true;
				newType.type = result;
			}
            else
            {
                DBG("mapping not found");
            }
		}
	}

	//writeln("-");

	assert(newType);
	string[] T_names;
	foreach(part; type.opSlice())
	{
		if (part.kind == CompletionKind.typeTmpParam)
		{
			T_names ~= part.name;
		}
		else
		if (part.type && part.type.kind == CompletionKind.typeTmpParam)
		{

			//print_tab(depth); writeln("part: ", part.name,": ", part.type.name);
			DSymbol* newPart = GCAllocator.instance.make!DSymbol(part.name, part.kind, null);
			newPart.qualifier = part.qualifier;
			newPart.protection = part.protection;
			newPart.symbolFile = part.symbolFile;
            newPart.location = part.location;
            newPart.location_end = part.location_end;
			newPart.doc = part.doc;
			newPart.callTip = part.callTip;

			if (part.type.name in mapping)
			{
				auto result = mapping[part.type.name];
				newPart.ownType = result.kind == CompletionKind.keyword ? false : true;
				newPart.type = result;
			}
			else if (m && part.type.name in m)
			{
				auto result =  m[part.type.name];
				newPart.ownType = result.kind == CompletionKind.keyword ? false : true;
				newPart.type = result;
			}

			newType.addChild(newPart, true);
		}

        // TODO:
        //  what if it's a ** or *** or **** ................. sadge
        //  don't duplicate this, but i'm too lazy to clean this right now
        else if (part.type && part.type.name == "*" && part.type.type && part.type.type.kind == CompletionKind.typeTmpParam)
        {
            auto arrSymbol = part.type;
            auto arrTypeTSymbol = arrSymbol.type;

            //print_tab(depth); writeln("array: ", part.name,": ", arrTypeTSymbol.name,"[]");


            DSymbol* newPart = GCAllocator.instance.make!DSymbol(part.name, part.kind, null);
            newPart.qualifier = part.qualifier;
            newPart.protection = part.protection;
            newPart.symbolFile = part.symbolFile;
            newPart.location = part.location;
            newPart.location_end = part.location_end;
            newPart.doc = part.doc;
            newPart.callTip = part.callTip;

            // create new array shit

            DBG("ptr: ", part.name," -> ", part.type.type.name);
            if (arrTypeTSymbol.name in mapping)
            {
                auto result = mapping[arrTypeTSymbol.name];
                DBG("  mapping found: ", arrTypeTSymbol.name," -> ", result.name);
                //print_tab(depth); writeln(" ", arrTypeTSymbol.name, " =>: ", result.name);

                auto newarr = GCAllocator.instance.make!DSymbol(arrSymbol.name , arrSymbol.kind, result);
                newarr.ownType = false;
                newarr.qualifier = arrSymbol.qualifier;
                //newarr.symbolFile = newPart.symbolFile;
                //newarr.location = newPart.location;
                newPart.type = newarr;
                newPart.ownType = true;
            }
            else
            {

            }

            newType.addChild(newPart, false);
        }
        else if (part.type && part.type.name == "*arr*" && part.type.type && part.type.type.kind == CompletionKind.typeTmpParam)
		{
			auto arrSymbol = part.type;
			auto arrTypeTSymbol = arrSymbol.type;

			//print_tab(depth); writeln("array: ", part.name,": ", arrTypeTSymbol.name,"[]");


			DSymbol* newPart = GCAllocator.instance.make!DSymbol(part.name, part.kind, null);
			newPart.qualifier = part.qualifier;
			newPart.protection = part.protection;
			newPart.symbolFile = part.symbolFile;
            newPart.location = part.location;
            newPart.location_end = part.location_end;
			newPart.doc = part.doc;
			newPart.callTip = part.callTip;

			// create new array shit


			if (arrTypeTSymbol.name in mapping)
			{
				auto result = mapping[arrTypeTSymbol.name];
				//print_tab(depth); writeln(" ", arrTypeTSymbol.name, " =>: ", result.name);

				auto newarr = GCAllocator.instance.make!DSymbol(arrSymbol.name , arrSymbol.kind, result);
				newarr.ownType = false;
                newarr.qualifier = arrSymbol.qualifier;
                //newarr.symbolFile = newPart.symbolFile;
                //newarr.location = newPart.location;
				newPart.type = newarr;
				newPart.ownType = true;
			}

			newType.addChild(newPart, false);
		}
		else
		{

			//print_tab(depth); writeln("missing part: ", part.name,": ", part.type);
			// BUG: doing it recursively messes with the mapping
			// i need to debug this and figure out perhaps a better way to do this stuff
			// maybe move the VariableContext to the symbol directly
			// i'll need to experiemnt with it

			//DSymbol* part_T;
			//if (depth < 50)
			//if (part.type && part.kind == CompletionKind.variableName)
			//foreach(partPart; part.type.opSlice())
			//{
			//    if (partPart.kind == CompletionKind.typeTmpParam)
			//    {
			//    	part_T = part;
			//        foreach(arg; ti.args)
			//        {
			//            warning(" > ", arg.chain);
			//            foreach(aa; arg.args)
			//            	warning("    > ", aa.chain);
			//        }
			//		int indepth = depth;
			//        warning("go agane ", part.name, " ", part.type.name, " with arg: ", ti.chain," Ts: ", T_names);
			//        resolveTemplate(part, part.type, lookup, ti, moduleScope, cache, indepth, mapping);
			//        break;
			//    }
			//    //else if (partPart.type && partPart.type.kind == CompletionKind.typeTmpParam)
			//    //{
			//    //	warning("here!".red," ", partPart.name," ", partPart.type.name);
			//    //}
			//}
			newType.addChild(part, false);
		}
	}
	return newType;
}

/**
 * Resolve template arguments
 */
void resolveTemplate(DSymbol* variableSym, DSymbol* type, TypeLookup* lookup, VariableContext.TypeInstance* current, Scope* moduleScope, ref ModuleCache cache, ref int depth, DSymbol*[string] mapping = null)
{
	depth += 1;

	if (variableSym is null || type is null) return;
	if (current.chain.length == 0) return; // TODO: should not be empty, happens for simple stuff Inner inner; TODO: i forgot why, add a test

	writeln("> Resolve template for: ",variableSym.name, ": ", type.name);
	writeln("  ctx callTip: ", lookup.ctx.calltip);


	void printti(VariableContext.TypeInstance* it, ref int index)
	{
		print_tab(index); write("chain:", it.chain, "name: ", it.name, " ct: ", it.calltip, " args: ", it.args.length, "\n");
		index += 1;
		foreach(itt; it.args)
		{
			int inindex = index;
			printti(itt, inindex);
		}
	}
	int index = 0;
	printti(lookup.ctx.root, index);

	writeln("");
	writeln("");
	DSymbol* newType = createTypeWithTemplateArgs(type, lookup, current, cache, moduleScope, depth, mapping);


	writeln("");
	writeln("resolved:", variableSym.name, " > ", newType.name,":", newType.kind,":", newType.qualifier,":", newType.callTip);
    if(newType.type)
    writeln("          :", newType.type.name,":", newType.type.kind,":",newType.type.qualifier,":",newType.type.callTip);
    writeln("    lookup:  ", lookup.ctx.calltip);
    writeln("    depth:  ", depth);



	if (depth == 1 && lookup.ctx.calltip.length > 0)
	{
        writeln("    depth replace: ", newType.name,":",newType.callTip);
		newType.name = istring(lookup.ctx.calltip);
	}

    //if (newType.qualifier == SymbolQualifier.array)
    //{
    //    writeln("it's arr, need adjust");
    //    auto arr = GCAllocator.instance.make!DSymbol(ARRAY_SYMBOL_NAME, CompletionKind.dummy, newType);
    //    arr.qualifier = SymbolQualifier.array;
    //    arr.ownType = false;
    //    arr.addChildren(arraySymbols[], false);

    //    newType = arr;
    //}


    //auto t = newType;
    //while(true)
    //{
    //    if (t.type !=null && (t.qualifier == SymbolQualifier.array||t.qualifier == SymbolQualifier.pointer))
    //    {
    //        t = t.type;
    //    }
    //    else break;
    //}
    //newType = t;


	variableSym.type = newType;
	variableSym.ownType = true;
}

void resolveImport(DSymbol* rootModule, DSymbol* acSymbol, ref TypeLookups typeLookups,
	ref ModuleCache cache)
in
{
	assert(acSymbol.kind == CompletionKind.importSymbol);
	assert(acSymbol.symbolFile !is null);
}
do
{

	DSymbol* moduleSymbol = cache.cacheModule(acSymbol.symbolFile);


	// store the module that imports it if it is a public import
	if (rootModule && moduleSymbol) // public import
	{
		//warning("store: ", rootModule.symbolFile," -> ", acSymbol.symbolFile);
		auto importedFromSym = GCAllocator.instance.make!(DSymbol)("*imported_from*", CompletionKind.dummy, rootModule);
		moduleSymbol.addChild(importedFromSym, true);
	}
	if (acSymbol.qualifier == SymbolQualifier.selectiveImport)
	{
		if (moduleSymbol is null)
		{
		tryAgain:
			DeferredSymbol* deferred = DeferredSymbolsAllocator.instance.make!DeferredSymbol(acSymbol);
			deferred.typeLookups.insert(typeLookups[]);
			// Get rid of the old references to the lookups, this new deferred
			// symbol owns them now
			typeLookups.clear();
			cache.deferredSymbols.insert(deferred);
		}
		else
		{
			immutable size_t breadcrumbCount = typeLookups.front.breadcrumbs.length;
			assert(breadcrumbCount <= 2 && breadcrumbCount > 0, "Malformed selective import");

			istring symbolName = typeLookups.front.breadcrumbs.front;
			DSymbol* selected = moduleSymbol.getFirstPartNamed(symbolName);
			if (selected is null)
				goto tryAgain;
			acSymbol.type = selected;
			acSymbol.ownType = false;

			// count of 1 means selective import
			// count of 2 means a renamed selective import
			if (breadcrumbCount == 2)
			{
				acSymbol.kind = CompletionKind.aliasName;
				acSymbol.symbolFile = acSymbol.altFile;
			}
		}
	}
	else
	{
		if (moduleSymbol is null)
		{
			DeferredSymbol* deferred = DeferredSymbolsAllocator.instance.make!DeferredSymbol(
				acSymbol);
			cache.deferredSymbols.insert(deferred);
		}
		else
		{
			acSymbol.type = moduleSymbol;
			acSymbol.ownType = false;
		}
	}
}

void resolveTypeFromType(DSymbol* symbol, TypeLookup* lookup, Scope* moduleScope,
	ref ModuleCache cache, Imports* imports)
in
{
	if (imports !is null)
		foreach (i; imports.opSlice())
			assert(i.kind == CompletionKind.importSymbol);
}
do
{
	// The left-most suffix
	DSymbol* suffix;
	// The right-most suffix
	DSymbol* lastSuffix;

	// Create symbols for the type suffixes such as array and
	// associative array
	while (!lookup.breadcrumbs.empty)
	{
		auto back = lookup.breadcrumbs.back;
		SymbolQualifier qualifier;
		if (back == ARRAY_SYMBOL_NAME) qualifier = SymbolQualifier.array;
		else if (back == ASSOC_ARRAY_SYMBOL_NAME) qualifier = SymbolQualifier.assocArray;
		else if (back == FUNCTION_SYMBOL_NAME) qualifier = SymbolQualifier.func;
		else if (back == POINTER_SYMBOL_NAME) qualifier = SymbolQualifier.pointer;
		else break;

		lastSuffix = GCAllocator.instance.make!DSymbol(back, CompletionKind.dummy, lastSuffix);
		lastSuffix.qualifier = qualifier;
		lastSuffix.ownType = true;

		final switch (qualifier)
		{
		case SymbolQualifier.none:
		case SymbolQualifier.selectiveImport:
			assert(false, "this should never be generated");
		case SymbolQualifier.func:
			lookup.breadcrumbs.popBack();
			lastSuffix.callTip = lookup.breadcrumbs.back();
			break;
		case SymbolQualifier.array: {

            //lastSuffix.callTip = istring("42");
            //writeln("   ARRAY   :", lookup.ctx.calltip,":", lookup.ctx.root.calltip);
            //writeln("           :", symbol.name,":",symbol.callTip);
            //writeln("           :", lastSuffix.name,":",lastSuffix.callTip);
            lastSuffix.addChildren(arraySymbols[], false); break;
        }
		case SymbolQualifier.assocArray: lastSuffix.addChildren(assocArraySymbols[], false); break;
		case SymbolQualifier.pointer: lastSuffix.addChildren(pointerSymbols[], false); break;
		case SymbolQualifier.templated: lastSuffix.addChildren(templatedSymbols[], false); break;
		}

		if (suffix is null)
			suffix = lastSuffix;
		lookup.breadcrumbs.popBack();
	}

	Imports remainingImports;

	DSymbol* currentSymbol;

	void getSymbolFromImports(Imports* importList, istring name)
	{
		foreach (im; importList.opSlice())
		{
			assert(im.symbolFile !is null);
			// Try to find a cached version of the module
			DSymbol* moduleSymbol = cache.getModuleSymbol(im.symbolFile);
			// If the module has not been cached yet, store it in the
			// remaining imports list
			if (moduleSymbol is null)
			{
				remainingImports.insert(im);
				continue;
			}
			// Try to get the symbol from the imported module
			currentSymbol = moduleSymbol.getFirstPartNamed(name);
			if (currentSymbol is null)
				continue;
		}
	}

	// Follow all the names and try to resolve them
	size_t i = 0;
	foreach (part; lookup.breadcrumbs[])
	{
		if (i == 0)
		{
			if (moduleScope is null)
				getSymbolFromImports(imports, part);
			else
			{
				auto symbols = moduleScope.getSymbolsByNameAndCursor(part, symbol.location);
				if (symbols.length > 0)
					currentSymbol = symbols[0];
				else
				{
					// store the part, that'll be useful to resolve the type later
					symbol.typeSymbolName = istring(part);
					return;
				}
			}
		}
		else
		{
			if (currentSymbol.kind == CompletionKind.aliasName)
				currentSymbol = currentSymbol.type;
			if (currentSymbol is null)
				return;
			if (currentSymbol.kind == CompletionKind.moduleName && currentSymbol.type !is null)
				currentSymbol = currentSymbol.type;
			if (currentSymbol is null)
				return;
			if (currentSymbol.kind == CompletionKind.importSymbol)
				currentSymbol = currentSymbol.type;
			if (currentSymbol is null)
				return;
			currentSymbol = currentSymbol.getFirstPartNamed(part);
		}
		++i;
		if (currentSymbol is null)
			return;
	}

	if (lastSuffix !is null)
	{
		assert(suffix !is null);
		typeSwap(currentSymbol);
		suffix.type = currentSymbol;
		suffix.ownType = false;
		symbol.type = lastSuffix;
		symbol.ownType = true;

		if (currentSymbol is null && !remainingImports.empty)
		{
			//			info("Deferring type resolution for ", symbol.name);
			auto deferred = DeferredSymbolsAllocator.instance.make!DeferredSymbol(suffix);
			// TODO: The scope has ownership of the import information
			deferred.imports.insert(remainingImports[]);
			deferred.typeLookups.insert(lookup);
			cache.deferredSymbols.insert(deferred);
		}
	}
	else if (currentSymbol !is null)
	{
		symbol.type = currentSymbol;
		symbol.ownType = false;
	}
	else if (!remainingImports.empty)
	{
		auto deferred = DeferredSymbolsAllocator.instance.make!DeferredSymbol(symbol);
		//		info("Deferring type resolution for ", symbol.name);
		// TODO: The scope has ownership of the import information
		deferred.imports.insert(remainingImports[]);
		deferred.typeLookups.insert(lookup);
		cache.deferredSymbols.insert(deferred);
	}
}

void resolveTypeFromInitializer(DSymbol* symbol, TypeLookup* lookup,
	Scope* moduleScope, ref ModuleCache cache)
{
	if (lookup.breadcrumbs.length == 0)
		return;
	DSymbol* currentSymbol = null;
	size_t i = 0;

	auto crumbs = lookup.breadcrumbs[];

	writeln(">> crumbs: ", crumbs);
	writeln(">> name:   ", symbol.name);
	foreach (crumb; crumbs)
	{
		if (i == 0)
		{
			currentSymbol = moduleScope.getFirstSymbolByNameAndCursor(
				symbolNameToTypeName(crumb), symbol.location);

			if (currentSymbol is null)
			{
				writeln("return 0");
				return;
			}
		}
		else if (crumb == ARRAY_LITERAL_SYMBOL_NAME)
		{
			auto arr = GCAllocator.instance.make!(DSymbol)(ARRAY_LITERAL_SYMBOL_NAME, CompletionKind.dummy, currentSymbol);
			arr.qualifier = SymbolQualifier.array;
			currentSymbol = arr;
		}
		else if (crumb == ARRAY_SYMBOL_NAME)
		{
			typeSwap(currentSymbol);
			if (currentSymbol is null)
			{
				writeln("return");
				return;
			}

			// Index expressions can be on a pointer, an array or an AA
			if (currentSymbol.qualifier == SymbolQualifier.array
				|| currentSymbol.qualifier == SymbolQualifier.assocArray
				|| currentSymbol.qualifier == SymbolQualifier.pointer
				|| currentSymbol.kind == CompletionKind.aliasName)
			{
				if (currentSymbol.type !is null)
				{
					writeln("here! ", currentSymbol.type.name);
					currentSymbol = currentSymbol.type;
				}
				else
				{
					writeln("nope!");
					return;
				}
			}
			else
			{
				auto opIndex = currentSymbol.getFirstPartNamed(internString("opIndex"));
				if (opIndex !is null)
					currentSymbol = opIndex.type;
				else
				{
					writeln("return weird");
					writeln("s: ", currentSymbol.name, " ", currentSymbol.qualifier);
					continue;
				}
			}
		}
		else if (crumb == "foreach")
		{
			typeSwap(currentSymbol);
			if (currentSymbol is null)
				return;
			if (currentSymbol.qualifier == SymbolQualifier.array
				|| currentSymbol.qualifier == SymbolQualifier.assocArray)
			{
				currentSymbol = currentSymbol.type;
				break;
			}
			auto front = currentSymbol.getFirstPartNamed(internString("front"));
			if (front !is null)
			{
				currentSymbol = front.type;
				break;
			}
			auto opApply = currentSymbol.getFirstPartNamed(internString("opApply"));
			if (opApply !is null)
			{
				currentSymbol = opApply.type;
				break;
			}
		}
		else
		{
			writeln("here");
			typeSwap(currentSymbol);
			if (currentSymbol is null)
			{

				writeln("return", i);
				return;
			}
			currentSymbol = currentSymbol.getFirstPartNamed(crumb);
		}
		++i;
		if (currentSymbol is null)
		{
			writeln("return end", i);
			return;
		}
	}
	typeSwap(currentSymbol);
	symbol.type = currentSymbol;
	symbol.ownType = false;

	if (currentSymbol)
		writeln(">> type:   ", currentSymbol.name);
}

private:

void resolveInheritance(DSymbol* symbol, ref TypeLookups typeLookups,
	Scope* moduleScope, ref ModuleCache cache)
{
	outer: foreach (TypeLookup* lookup; typeLookups[])
	{
		if (lookup.kind != TypeLookupKind.inherit)
			continue;
		DSymbol* baseClass;
		assert(lookup.breadcrumbs.length > 0);

		// TODO: Delayed type lookup
		auto symbolScope = moduleScope.getScopeByCursor(
			symbol.location + symbol.name.length);
		auto symbols = moduleScope.getSymbolsByNameAndCursor(lookup.breadcrumbs.front,
			symbol.location);
		if (symbols.length == 0)
			continue;

		baseClass = symbols[0];
		lookup.breadcrumbs.popFront();
		foreach (part; lookup.breadcrumbs[])
		{
			symbols = baseClass.getPartsByName(part);
			if (symbols.length == 0)
				continue outer;
			baseClass = symbols[0];
		}

		DSymbol* imp = GCAllocator.instance.make!DSymbol(IMPORT_SYMBOL_NAME,
			CompletionKind.importSymbol, baseClass);
		symbol.addChild(imp, true);
		symbolScope.addSymbol(imp, false);
		if (baseClass.kind == CompletionKind.className)
		{
			auto s = GCAllocator.instance.make!DSymbol(SUPER_SYMBOL_NAME,
				CompletionKind.variableName, baseClass);
			symbolScope.addSymbol(s, true);
		}
	}
}

void resolveAliasThis(DSymbol* symbol,
	ref TypeLookups typeLookups, Scope* moduleScope, ref ModuleCache cache)
{
	foreach (aliasThis; typeLookups[].filter!(a => a.kind == TypeLookupKind.aliasThis))
	{
		assert(aliasThis.breadcrumbs.length > 0);
		auto parts = symbol.getPartsByName(aliasThis.breadcrumbs.front);
		if (parts.length == 0 || parts[0].type is null)
			continue;

		symbol.aliasThisSymbols ~= parts;

		DSymbol* s = GCAllocator.instance.make!DSymbol(IMPORT_SYMBOL_NAME,
			CompletionKind.importSymbol, parts[0].type);
		symbol.addChild(s, true);
		auto symbolScope = moduleScope.getScopeByCursor(s.location);
		if (symbolScope !is null)
			symbolScope.addSymbol(s, false);
	}
}

void resolveMixinTemplates(DSymbol* symbol,
	ref TypeLookups typeLookups, Scope* moduleScope, ref ModuleCache cache)
{
	foreach (mix; typeLookups[].filter!(a => a.kind == TypeLookupKind.mixinTemplate))
	{
		assert(mix.breadcrumbs.length > 0);
		auto symbols = moduleScope.getSymbolsByNameAndCursor(mix.breadcrumbs.front,
			symbol.location);
		if (symbols.length == 0)
			continue;
		auto currentSymbol = symbols[0];
		mix.breadcrumbs.popFront();
		foreach (m; mix.breadcrumbs[])
		{
			auto s = currentSymbol.getPartsByName(m);
			if (s.length == 0)
			{
				currentSymbol = null;
				break;
			}
			else
				currentSymbol = s[0];
		}
		if (currentSymbol !is null)
		{
			auto i = GCAllocator.instance.make!DSymbol(IMPORT_SYMBOL_NAME,
				CompletionKind.importSymbol, currentSymbol);
			i.ownType = false;
			symbol.addChild(i, true);
		}
	}
}

void resolveType(DSymbol* symbol, ref TypeLookups typeLookups,
	Scope* moduleScope, ref ModuleCache cache)
{
	// going through the lookups
	foreach(lookup; typeLookups) {
		if (lookup.kind == TypeLookupKind.varOrFunType)
			resolveTypeFromType(symbol, lookup, moduleScope, cache, null);
		else if (lookup.kind == TypeLookupKind.initializer)
			resolveTypeFromInitializer(symbol, lookup, moduleScope, cache);
		// issue 94
		else if (lookup.kind == TypeLookupKind.inherit)
			resolveInheritance(symbol, typeLookups, moduleScope, cache);
		else
			assert(false, "How did this happen?");
		}
}

void typeSwap(ref DSymbol* currentSymbol)
{
	while (currentSymbol !is null && currentSymbol.type !is currentSymbol
		&& (currentSymbol.kind == CompletionKind.variableName
			|| currentSymbol.kind == CompletionKind.importSymbol
			|| currentSymbol.kind == CompletionKind.withSymbol
			|| currentSymbol.kind == CompletionKind.aliasName))
		currentSymbol = currentSymbol.type;
}