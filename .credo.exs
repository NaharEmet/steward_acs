%{
  configs: [
    %{
      name: "default",
      files: %{included: ["lib/", "test/", "config/"]},
      checks: [
        {Credo.Check.Warning.StructFieldAmount, max_fields: 35},

        {Credo.Check.Design.AliasUsage, false},
        {Credo.Check.Design.DuplicatedCode, false},
        {Credo.Check.Design.SkipTestWithoutComment, false},
        {Credo.Check.Design.TagFIXME, false},
        {Credo.Check.Design.TagTODO, false},

        {Credo.Check.Refactor.Apply, false},
        {Credo.Check.Refactor.CondStatements, false},
        {Credo.Check.Refactor.CyclomaticComplexity, false},
        {Credo.Check.Refactor.FilterFilter, false},
        {Credo.Check.Refactor.FilterReject, false},
        {Credo.Check.Refactor.FunctionArity, false},
        {Credo.Check.Refactor.MapJoin, false},
        {Credo.Check.Refactor.MatchInCondition, false},
        {Credo.Check.Refactor.NegatedConditionsWithElse, false},
        {Credo.Check.Refactor.Nesting, false},
        {Credo.Check.Refactor.RedundantWithClauseResult, false},
        {Credo.Check.Refactor.RejectFilter, false},
        {Credo.Check.Refactor.RejectReject, false},
        {Credo.Check.Refactor.UnlessWithElse, false},

        {Credo.Check.Readability.AliasOrder, false},
        {Credo.Check.Readability.LargeNumbers, false},
        {Credo.Check.Readability.MaxLineLength, false},
        {Credo.Check.Readability.ModuleDoc, false},
        {Credo.Check.Readability.ParenthesesInCondition, false},
        {Credo.Check.Readability.PredicateFunctionNames, false},
        {Credo.Check.Readability.PreferImplicitTry, false},
        {Credo.Check.Readability.WithSingleClause, false}
      ]
    }
  ]
}
