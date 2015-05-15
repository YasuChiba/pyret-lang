#lang pyret

provide *
provide-types *
import file as F
import ast as A
import parse-pyret as PP
import "compiler/js-of-pyret.arr" as P
import "compiler/compile-structs.arr" as C
import "compiler/well-formed.arr" as W
import "compiler/ast-util.arr" as U
import "compiler/resolve-scope.arr" as R
import "compiler/desugar.arr" as D
import "compiler/desugar-post-tc.arr" as DP
import "compiler/type-check.arr" as T
import "compiler/desugar-check.arr" as CH

data CompilationPhase:
  | start
  | phase(name :: String, result :: Any, prev :: CompilationPhase)
sharing:
  tolist(self):
    fun help(the-phase, acc):
      if is-start(the-phase): acc
      else: help(the-phase.prev, {name : the-phase.name, result : the-phase.result} ^ link(_, acc))
      end
    end
    help(self, empty)
  end
end

fun compile-js-ast(phases, ast, name, env, libs, options) -> CompilationPhase:
  var ret = phases
  ast-ended = U.append-nothing-if-necessary(ast)
  when options.collect-all:
    when is-some(ast-ended): ret := phase("Added nothing", ast-ended.value, ret) end
  end
  wf = W.check-well-formed(ast-ended.or-else(ast))
  when options.collect-all: ret := phase("Checked well-formedness", wf, ret) end
  checker = if options.check-mode: CH.desugar-check else: CH.desugar-no-checks;
  cases(C.CompileResult) wf:
    | ok(wf-ast) =>
      checked = checker(wf-ast)
      when options.collect-all:
        ret := phase(if options.check-mode: "Desugared (with checks)" else: "Desugared (skipping checks)" end,
          checked, ret)
      end
      imported = U.wrap-extra-imports(checked, libs)
      when options.collect-all: ret := phase("Added imports", imported, ret) end
      scoped = R.desugar-scope(imported)
      when options.collect-all: ret := phase("Desugared scope", scoped, ret) end
      named-result = R.resolve-names(scoped, env)
      when options.collect-all: ret := phase("Resolved names", named-result, ret) end
      named-ast = named-result.ast
      named-errors = named-result.errors
      desugared = D.desugar(named-ast)
      when options.collect-all: ret := phase("Fully desugared", desugared, ret) end
      type-checked =
        if options.type-check: T.type-check(desugared, env)
        else: C.ok(desugared);
      when options.collect-all: ret := phase("Type Checked", type-checked, ret) end
      cases(C.CompileResult) type-checked:
        | ok(tc-ast) =>
          dp-ast = DP.desugar-post-tc(tc-ast, env)
          cleaned = dp-ast.visit(U.merge-nested-blocks)
                          .visit(U.flatten-single-blocks)
                          .visit(U.link-list-visitor(env))
                          .visit(U.letrec-visitor)
          when options.collect-all: ret := phase("Cleaned AST", cleaned, ret) end
          inlined = cleaned.visit(U.inline-lams)
          when options.collect-all: ret := phase("Inlined lambdas", inlined, ret) end
          any-errors = named-errors + U.check-unbound(env, inlined) + U.bad-assignments(env, inlined)
          if is-empty(any-errors):
            if options.collect-all: P.trace-make-compiled-pyret(ret, phase, inlined, env)
            else: phase("Result", C.ok(P.make-compiled-pyret(inlined, env, options)), ret)
            end
          else:
            if options.collect-all and options.ignore-unbound: P.trace-make-compiled-pyret(ret, phase, inlined, env)
            else: phase("Result", C.err(any-errors), ret)
            end
          end
        | err(_) => phase("Result", type-checked, ret)
      end
    | err(_) => phase("Result", wf, ret)
  end
end

fun compile-js(trace, dialect, code, name, env :: C.CompileEnvironment, libs :: C.ExtraImports, options)
  -> CompilationPhase<C.CompileResult<P.CompiledCodePrinter, Any>>:
  var ret = trace
  ast = PP.parse-dialect(dialect, code, name)
  when options.collect-all: ret := phase("Parsed (" + dialect + " dialect)", ast, ret) end
  compile-js-ast(ret, ast, name, env, libs, options)
end

