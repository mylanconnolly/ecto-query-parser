defmodule EctoQueryParser.Test.Company do
  use Ecto.Schema

  schema "companies" do
    field :company_name, :string
  end
end

defmodule EctoQueryParser.Test.Author do
  use Ecto.Schema

  schema "authors" do
    field :name, :string
    field :email, :string
    belongs_to :company, EctoQueryParser.Test.Company
    has_many :posts, EctoQueryParser.Test.TestSchema
  end
end

defmodule EctoQueryParser.Test.TestSchema do
  use Ecto.Schema

  schema "test_items" do
    field :name, :string
    field :age, :integer
    field :score, :float
    field :active, :boolean
    field :tags, {:array, :string}
    field :body, :string
    field :role, :string
    field :status, :string
    field :metadata, :map
    field :created_at, :utc_datetime
    belongs_to :author, EctoQueryParser.Test.Author
  end
end
