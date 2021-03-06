%w(rubygems active_support).each { |f| require f }

module Workflow
  @@logger = nil
  def self.logger=(obj) @@logger = obj; end
  def logger=(obj) @@logger = obj; end
  def self.logger() @@logger; end
  def logger() @@logger; end

  WORKFLOW_DEFAULT_LOGGER = Logger.new(STDERR)
  WORKFLOW_DEFAULT_LOGGER.level = Logger::WARN

  @@specifications = {}

  class << self

    def specify(name = :default, meta = {:meta => {}}, &specification)
      if @@specifications[name]
        @@specifications[name].blat(meta[:meta], &specification)
      else
        @@specifications[name] = Specification.new(meta[:meta], &specification)
      end
    end

    def reset!
      @@specifications = {}
    end

  private

    def find_spec_for(klass) # it could either be a symbol, or a class, man, urgh.
      target = klass
      while @@specifications[target].nil? and target != Object
        target = target.superclass
      end
      @@specifications[target]
    end

  public

    def new(name = :default, args = {})
      find_spec_for(name).to_instance(args[:reconstitute_at])
    end

    def reconstitute(reconstitute_at = nil, name = :default)
      find_spec_for(name).to_instance(reconstitute_at)
    end

    def active_record?(receiver)
      if receiver.nil?
        false
      else
        receiver.ancestors.include?(ActiveRecord::Base)
      end
    end

    def append_features(receiver)
      if active_record?(receiver)
        receiver.instance_eval do
          def workflow(workflow_name = :workflow, bind = true, &specification)
            workflow_name = workflow_name.to_s

            Workflow.logger.debug "Adding Workflow to ActiveRecord object #{self}"
            Workflow.specify("#{name}-#{workflow_name}", &specification)

            class_eval <<-RUBY
              attr_accessor :#{workflow_name}

              def initialize_with_#{workflow_name}(attributes = nil)
                Workflow.logger.debug "calling Workflow's redefined initializer"
                initialize_without_#{workflow_name}(attributes)
                @#{workflow_name} = Workflow.new(\"#{name}-#{workflow_name}\")
                @#{workflow_name}.bind_to(self) if #{bind}
                self.#{workflow_name}_state = Workflow.new(\"#{name}-#{workflow_name}\").state.to_s if #{workflow_name}_state.nil?
              end
              alias_method_chain :initialize, :#{workflow_name}

              unless method_defined?(:after_find)
                def after_find; end;
              end

              def after_find_with_#{workflow_name}
                Workflow.logger.debug "after find called"
                @#{workflow_name} = if #{workflow_name}_state.nil?
                              Workflow.new(\"#{name}-#{workflow_name}\")
                            else
                              Workflow.reconstitute(#{workflow_name}_state.to_sym, \"#{name}-#{workflow_name}\")
                            end
                @#{workflow_name}.bind_to(self) if #{bind}
                after_find_without_#{workflow_name}
              end
              alias_method_chain :after_find, :#{workflow_name}

              def reload_with_#{workflow_name}_state
                reload_without_#{workflow_name}_state
                after_find
              end
              alias_method_chain :reload, :#{workflow_name}_state

              Workflow.new(\"#{name}-#{workflow_name}\").states.each do |state|
                named_scope state, { :conditions => { :#{workflow_name}_state => state.to_s } } unless respond_to?(state)
              end
            RUBY
          end
        end
      else
        Workflow.logger.debug "Adding Workflow to object #{self}"

        receiver.instance_eval do
          def workflow(&specification)
            Workflow.specify(self, &specification)
          end
        end

        # anything else gets this style of integration
        receiver.class_eval do
          alias_method :initialize_before_workflow, :initialize
          attr_reader :workflow

          def initialize(*args, &block)
            initialize_before_workflow(*args, &block)
            @workflow = Workflow.new(self.class)
            @workflow.bind_to(self)
          end
        end
      end
    end
  end

  class Specification

    attr_accessor :states, :meta, :on_transition

    def initialize(meta = {}, &specification)
      @states = []
      @meta = meta
      instance_eval(&specification)
    end

    def to_instance(reconstitute_at = nil)
      Instance.new(states, @on_transition, @meta, reconstitute_at)
    end

    def blat(meta = {}, &specification)
      instance_eval(&specification)
    end

  private

    def state(name, meta = {:meta => {}}, &events_and_etc)
      Workflow.logger.debug "Defining state(#{name}) for #{self}"
      # meta[:meta] to keep the API consistent..., gah
      self.states << State.new(name, meta[:meta])
      instance_eval(&events_and_etc) if events_and_etc
    end

    def on_transition(&proc)
      @on_transition = proc
    end

    def event(name, args = {}, &action)
      scoped_state.add_event Event.new(name, args[:transitions_to], (args[:meta] or {}), args[:if], &action)
    end

    def on_entry(&proc)
      scoped_state.on_entry = proc
    end

    def on_exit(&proc)
      scoped_state.on_exit = proc
    end

    def scoped_state
      states.last
    end

  end

  class Instance

    class TransitionHalted < Exception
      attr_reader :halted_because

      def initialize(msg = nil)
        @halted_because = msg
        super msg
      end
    end

    attr_accessor :states, :meta, :current_state, :on_transition, :context

    def initialize(states, on_transition, meta = {}, reconstitute_at = nil)
      Workflow.logger.debug "Creating workflow instance"
      @states, @on_transition, @meta = states, on_transition, meta
      @context = self
      if reconstitute_at.nil?
        transition(nil, states.first, nil)
      else
        self.current_state = states(reconstitute_at)
      end
    end

    def current_state=(var)
      @current_state=var
    end

    def state(fetch = nil)
      if fetch
        states(fetch)
      else
        current_state.name
      end
    end

    def states(name = nil)
      if name
        @states.detect { |s| s.name == name }
      else
        @states.collect { |s| s.name }
      end
    end

    def available_events
      return [ ] if @skip_available_events # prevents recursion within method_missing
      @skip_available_events = true
      result = self.current_state.events.select do |e|
        test_condition(self.current_state.events(e).condition)
      end
      @skip_available_events = false
      result
    end

    def method_missing(name, *args)
      if current_state.events(name)
        process_event!(name, *args)
      elsif name.to_s[-1].chr == '?' and states(name.to_s[0..-2].to_sym)
        current_state == states(name.to_s[0..-2].to_sym)
      else
        super
      end
    end

    def bind_to(another_context)
      self.context = another_context
      patch_context(another_context) if another_context != self
    end

    def halted?
      @halted
    end

    def halted_because
      @halted_because
    end

  private

    def patch_context(context)
      Workflow.logger.debug "patching context of #{context.inspect} to include @workflow"
      context.instance_variable_set("@workflow", self)
      context.instance_eval do
        alias :method_missing_before_workflow :method_missing
        alias :respond_to_before_workflow :respond_to?

        # rails 2.2 is stricter about method_missing, now we need respond_to
        def respond_to?(method, include_private=false)
          if potential_methods.include?(method.to_sym)
            return true
          else
            respond_to_before_workflow(method, include_private)
          end
        end

        def method_missing(method, *args)
          Workflow.logger.debug "#{self} method missing: #{method}(#{args.inspect})"
          # we create an array of valid method names that can be delegated to the workflow,
          # otherwise methods are sent onwards down the chain.
          # this solves issues with catching a NoMethodError when it means something OTHER than a method missing in the workflow instance
          # for example, perhaps a NoMethodError is raised in an on_entry block or similar.
          # "potential_methods" should probably be calculated elsewhere, not per invocation
          if potential_methods.include?(method.to_sym)
            @workflow.send(method, *args)
          else
            method_missing_before_workflow(method, *args)
          end
        end

        def potential_methods
          [ :available_events, :current_state, :halt!, :halt, :halted?, :halted_because, :override_state_with, :state, :states, :transition ] +
            @workflow.available_events +
            (@workflow.states.collect {|s| "#{s}?".to_sym})
        end
      end
    end

    def process_event!(name, *args)
      event = current_state.events(name)
      @halted_because = nil
      @halted = false
      @raise_exception_on_halt = false
      halt!("condition on #{name} didn't pass") unless test_condition(event.condition, *args)
      # i don't think we've tested that the return value is
      # what the action returns... so yeah, test it, at some point.
      return_value = run_action(event.action, *args) unless @halted
      if @halted
        if @raise_exception_on_halt
          raise TransitionHalted.new(@halted_because)
        else
          false
        end
      else
        run_on_transition(current_state, states(event.transitions_to), name, *args)
        transition(current_state, states(event.transitions_to), name, *args)
        return_value
      end
    end

    def halt(reason = nil)
      @halted_because = reason
      @halted = true
      @raise_exception_on_halt = false
    end

    def halt!(reason = nil)
      @halted_because = reason
      @halted = true
      @raise_exception_on_halt = true
    end

    # TODO: There is identical code up int he Workflow module - remove the duplication
    def active_record?(receiver)
      if receiver.nil?
        false
      else
        receiver.class.ancestors.include?(ActiveRecord::Base)
      end
    end

    def transition(from, to, name, *args)
      run_on_exit(from, to, name, *args)
      self.current_state = to
      if active_record?(@context)
        @context.workflow_state = to.name.to_s    # may not have been defined when bind_to is called
        @context.workflow_state_changed_at = Time.now if @context.has_attribute?("workflow_state_changed_at")
      end
      run_on_entry(to, from, name, *args)
    end

    def run_on_transition(from, to, event, *args)
      context.instance_exec(from.name, to.name, event, *args, &on_transition) if on_transition
    end

    def run_action(action, *args)
      context.instance_exec(*args, &action) if action
    end

    def run_on_entry(state, prior_state, triggering_event, *args)
      if state.on_entry
        context.instance_exec(prior_state.name, triggering_event, *args, &state.on_entry)
      end
    end

    def run_on_exit(state, new_state, triggering_event, *args)
      if state and state.on_exit
        context.instance_exec(new_state.name, triggering_event, *args, &state.on_exit)
      end
    end

    def test_condition(condition, *args)
      return true if condition.nil?
      context.instance_exec(*args, &condition)
    end
  end

  class State

    attr_accessor :name, :events, :meta, :on_entry, :on_exit

    def initialize(name, meta = {})
      @name, @events, @meta = name, [], meta
    end

    def events(name = nil)
      if name
        @events.detect { |e| e.name == name }
      else
        @events.collect { |e| e.name }
      end
    end

    def add_event(event)
      @events << event
    end

  end

  class Event

    attr_accessor :name, :transitions_to, :meta, :action, :condition

    def initialize(name, transitions_to, meta = {}, condition = Proc.new { true }, &action)
      @name, @transitions_to, @meta, @condition, @action = name, transitions_to, meta, condition, action
    end

  end

end

Workflow.logger = Workflow::WORKFLOW_DEFAULT_LOGGER
