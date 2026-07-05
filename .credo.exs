%{
  configs: [
    %{
      name: "default",
      files: %{included: ["lib/", "test/", "config/"]},
      checks: [
        {Credo.Check.Warning.StructFieldAmount, max_fields: 35}
      ]
    }
  ]
}
