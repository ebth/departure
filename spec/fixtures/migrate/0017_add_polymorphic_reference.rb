# frozen_string_literal: true

class AddPolymorphicReference < ActiveRecord::Migration[5.1]
  def change
    add_reference(:comments, :user, polymorphic: true)
  end
end
