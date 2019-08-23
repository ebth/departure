# frozen_string_literal: true

class RenameCommentsToNewComments < ActiveRecord::Migration[5.1]
  def change
    rename_table :comments, :new_comments
  end
end
