# Minimal stand-ins for the SketchUp runtime, enough to load main.rb outside
# SketchUp and drive its socket loop.

module Sketchup
  def self.active_model; nil; end
  def self.version; "17.2.2555"; end
  def self.is_pro?; false; end
  def self.require(*); true; end
  def self.send_action(*); true; end
  def self.register_extension(*); true; end
end

module UI
  class FakeMenu
    def add_submenu(*); FakeMenu.new; end
    def add_item(*); yield if false; 1; end
  end

  def self.menu(*); FakeMenu.new; end
  # The real UI.start_timer schedules a repeating callback. Tests drive poll
  # manually instead, so just record the block.
  def self.start_timer(_interval, _repeat = false, &blk); $timer_block = blk; 1; end
  def self.stop_timer(*); $timer_block = nil; true; end
end

module FakeConsole
  def self.show; true; end
  def self.write(msg); $log_lines << msg if $log_lines; true; end
end
SKETCHUP_CONSOLE = FakeConsole

def file_loaded?(_f); false; end
def file_loaded(_f); true; end
