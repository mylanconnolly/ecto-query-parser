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
    field :hired_on, :date
    belongs_to :company, EctoQueryParser.Test.Company
    has_many :posts, EctoQueryParser.Test.TestSchema
  end
end

defmodule EctoQueryParser.Test.Tag do
  use Ecto.Schema

  schema "tags" do
    field :name, :string
  end
end

defmodule EctoQueryParser.Test.PostTag do
  use Ecto.Schema

  @primary_key false
  schema "post_tags" do
    belongs_to :post, EctoQueryParser.Test.TestSchema
    belongs_to :tag, EctoQueryParser.Test.Tag
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
    field :performed_on, :date
    field :balance, :decimal
    belongs_to :author, EctoQueryParser.Test.Author

    many_to_many :tag_list, EctoQueryParser.Test.Tag,
      join_through: EctoQueryParser.Test.PostTag,
      join_keys: [post_id: :id, tag_id: :id]
  end
end
