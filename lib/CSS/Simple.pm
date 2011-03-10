# $Id: Simple.pm 3044 2011-03-10 19:59:50Z kamelkev $
#
# Copyright 2011 MailerMailer, LLC - http://www.mailermailer.com
#
# Based in large part on the CSS::Tiny CPAN Module
# http://search.cpan.org/~adamk/CSS-Tiny/

package CSS::Simple;

use strict;
use warnings;

use vars qw($VERSION);
$VERSION = sprintf "%d", q$Revision: 3044 $ =~ /(\d+)/;

use Tie::IxHash;
use Storable qw(dclone);

=pod

=head1 NAME

CSS::Simple - Interface through which to read/write/manipulate CSS files while respecting the cascade order

=head1 SYNOPSIS

 use CSS::Simple;

 my $css = new CSS::Simple();

 $css->read({ filename => 'input.css' });

 #perform manipulations...

 $css->write({ filename => 'output.css' });

=head1 DESCRIPTION

Class for reading, manipulating and writing CSS. Unlike other CSS classes on CPAN this particular module
focuses on respecting the order of selectors while providing a common sense API through which to manipulate the
rules.

Please note that while ordering is respected, the exact order of selectors may change. I.e. the rules
implied by the styles and their ordering will not change, but the actual ordering of the styles may shift around.
See the read method for more information.

=head1 CONSTRUCTOR

=over 4

=item new ([ OPTIONS ])

Instantiates the CSS::Simple object. Sets up class variables that are used during file parsing/processing.

B<suppress_errors> (optional). Boolean value to indicate whether fatal errors should occur during parse failures.

=back
=cut

sub new {
  my ($proto, $params) = @_;

  my $class = ref($proto) || $proto;

  my $css = {};

  my $self = {
              stylesheet => undef,
              ordered => tie(%{$css}, 'Tie::IxHash'),
              suppress_errors => (defined($$params{suppress_errors}) && $$params{suppress_errors}) ? 1 : 0
             };

  bless $self, $class;
  return $self;
}

=head1 METHODS

=cut

=pod

=over 4

=item read_file( params )

Opens and reads a CSS file, then subsequently performs the parsing of the CSS file
necessary for later manipulation.

This method requires you to pass in a params hash that contains a
filename argument. For example:

$self->read_file({filename => 'myfile.css'});

=cut

sub read_file {
  my ($self,$params) = @_;

  $self->_check_object();

  unless ($params && $$params{filename}) {
    die "You must pass in hash params that contain a filename argument";
  }

  open FILE, "<", $$params{filename} or die $!;
  my $css = do { local( $/ ) ; <FILE> } ;

  $self->read({css => $css});

  return();
}

=pod

=item read( params )

Reads css data and parses it. The intermediate data is stored in class variables.

Compound selectors (i.e. "a, span") are split apart during parsing and stored
separately, so the output of any given stylesheet may not match the output 100%, but the 
rules themselves should apply as expected.

Ordering of selectors may shift if the same selector is seen twice within the stylesheet.
The precendence for any given selector is the last time it was seen by the parser.

This method requires you to pass in a params hash that contains scalar
css data. For example:

$self->read({css => $css});

=cut

sub read {
  my ($self,$params) = @_;

  $self->_check_object();

  if ($params && $$params{css}) {
    # Flatten whitespace and remove /* comment */ style comments
    my $string = $$params{css};
    $string =~ tr/\n\t/  /;
    $string =~ s!/\*.*?\*\/!!g;

    # Split into styles
    foreach ( grep { /\S/ } split /(?<=\})/, $string ) {

      unless ( /^\s*([^{]+?)\s*\{(.*)\}\s*$/ ) {
        $self->_report_error({ info => "Invalid or unexpected style data '$_'" });
        next;
      }

      # Split in such a way as to support grouped styles
      my $rule = $1;
      my $props = $2;

      $rule =~ s/\s{2,}/ /g;

      # Split into properties
      my $properties = {};
      foreach ( grep { /\S/ } split /\;/, $props ) {

        # skip over browser specific properties
        if ((/^\s*[\*\-\_]/) || (/\\/)) {
          next; 
        }

        # check if properties are valid, reporting error as configured        
        unless ( /^\s*([\w._-]+)\s*:\s*(.*?)\s*$/ ) {
          $self->_report_error({ info => "Invalid or unexpected property '$_' in style '$rule'" });
          next;
        }

        #store the property for later
        $$properties{lc $1} = $2;
      }

      my @selectors = split /,/, $rule; # break the rule into the component selector(s)

      #apply the found rules to each selector
      foreach my $selector (@selectors) {
        $selector =~ s/^\s+|\s+$//g;
        if ($self->check_selector({selector => $selector})) { #check if we already exist
          my $old_properties = $self->get_properties({selector => $selector});
          $self->delete_selector({selector => $selector});

          my %merged = (%$old_properties, %$properties);

          $self->add_selector({selector => $selector, properties => \%merged});
        }
        else {
          #store the properties within this selector
          $self->add_selector({selector => $selector, properties => $properties});
        }
      }
    }
  }
  else {
    $self->_report_error({ info => 'You must pass in hash params that contains the css data'});
  }

  return();
}

=pod

=item write_file()

Write the parsed and manipulated CSS out to a file parameter

This method requires you to pass in a params hash that contains a
filename argument. For example:

$self->write_file({filename => 'myfile.css'});

=cut

sub write_file {
  my ($self,$params) = @_;

  $self->_check_object();

  unless (exists $$params{filename}) {
    die "No filename specified for write operation";
  }

  # Write the file
  open( CSS, '>'. $$params{filename} ) or die "Failed to open file '$$params{filename}' for writing: $!";
  print CSS $self->write();
  close( CSS );

  return();
}

=pod

=item write()

Write the parsed and manipulated CSS out to a scalar and return it

=cut

sub write {
  my ($self,$params) = @_;

  $self->_check_object();

  my $contents = '';

  foreach my $selector ( $self->_get_ordered()->Keys ) {

    #grab the properties that make up this particular selector
    my $properties = $self->get_properties({selector => $selector});

    if (keys(%{$properties})) { # only output if the selector has properties
      $contents .= "$selector {\n";
      foreach my $property ( sort keys %{ $properties } ) {
        $contents .= "\t" . lc($property) . ": ".$properties->{$property}. ";\n";
      }
      $contents .= "}\n";
    }
  }

  return $contents;
}

####################################################################
#                                                                  #
# The following are all get/set methods for manipulating the       #
# stored stylesheet                                                #
#                                                                  #
# Provides a nicer interface than dealing with TIE                 #
#                                                                  #
####################################################################

=pod

=item get_selectors( params )

Get an array of selectors that represents an inclusive list of all selectors
stored.

=cut

sub get_selectors {
  my ($self,$params) = @_;

  $self->_check_object();

  return($self->_get_ordered()->Keys());
}

=pod

=item get_properties( params )

Get a hash that represents the various properties for this particular selector

This method requires you to pass in a params hash that contains scalar
css data. For example:

$self->get_properties({selector => '.foo'});

=cut

sub get_properties {
  my ($self,$params) = @_;

  $self->_check_object();

  return($self->_get_ordered()->FETCH($$params{selector}));
}

=pod

=item check_selector( params )

Determine if a selector exists within the stored rulesets

This method requires you to pass in a params hash that contains scalar
css data. For example:

$self->check_selector({selector => '.foo'});

=cut

sub check_selector {
  my ($self,$params) = @_;

  $self->_check_object();

  return($self->_get_ordered()->EXISTS($$params{selector}));
}

=pod

=item modify_selector( params )

Modify an existing selector
 
Modifying a selector maintains the existing selectivity of the rule with relation to the 
original stylesheet. If you want to ignore that selectivity, delete the element and re-add
it to CSS::Simple

This method requires you to pass in a params hash that contains scalar
css data. For example:

$self->modify_selector({selector => '.foo', new_selector => '.bar' });

=cut

sub modify_selector {
  my ($self,$params) = @_;

  $self->_check_object();

  #if the selector is found, replace the selector
  if ($self->check_selector({selector => $$params{selector}})) {
    #we probably want to be doing this explicitely
    my ($index) = $self->_get_ordered()->Indices( $$params{selector} );
    my $properties = $self->get_properties({selector => $$params{selector}});

    $self->_get_ordered()->Replace($index,$properties,$$params{new_selector});
  }
  #otherwise new element, stick it onto the end of the rulesets
  else {
    #add a selector, there was nothing to replace
    $self->add_selector({selector => $$params{new_selector}, properties => {}});
  }

  return();
}

=pod

=item add_selector( params )

Add a selector and associated properties to the stored rulesets

In the event that this particular ruleset already exists, invoking this method will
simply replace the item. This is important - if you are modifying an existing rule 
using this method than the previously existing selectivity will continue to persist.
Delete the selector first if you want to ignore the previous selectivity.

This method requires you to pass in a params hash that contains scalar
css data. For example:

$self->add_selector({selector => '.foo', properties => {color => 'red' }});

=cut

sub add_selector {
  my ($self,$params) = @_;

  $self->_check_object();

  #if we existed already, invoke REPLACE to preserve selectivity
  if ($self->check_selector({selector => $$params{selector}})) {
    #we probably want to be doing this explicitely
    my ($index) = $self->_get_ordered()->Indices( $$params{selector} );

    $self->_get_ordered()->Replace($index,dclone($$params{properties}));
  }
  #new element, stick it onto the end of the rulesets
  else {
    #store the properties
    $self->_get_ordered()->STORE($$params{selector},dclone($$params{properties}));
  }

  return();
}

=pod

=item add_properties( params )

Add properties to an existing selector, preserving the selectivity of the original declaration.

In the event that this method is invoked with a selector that doesn't exist then the call
is just translated to an add_selector call, thus creating the rule at the end of the ruleset.

This method requires you to pass in a params hash that contains scalar
css data. For example:

$self->add_properties({selector => '.foo', properties => {color => 'red' }});

=cut

sub add_properties {
  my ($self,$params) = @_;

  $self->_check_object();

  #If selector exists already, merge properties into this selector
  if ($self->check_selector({selector => $$params{selector}})) {
    #merge property sets together
    my %properties = (%{$self->get_properties({selector => $$params{selector}})}, %{$$params{properties}});

    #overwrite the existing properties for this selector with the new hybrid style
    $self->add_selector({selector => $$params{selector}, properties => \%properties});
  }
  #otherwise add it wholesale
  else {
    $self->add_selector({selector => $$params{selector}, properties => $$params{properties}});
  }

  return();
}

=pod

=item delete_selector( params )

Delete a selector from the ruleset

This method requires you to pass in a params hash that contains scalar
css data. For example:

$self->delete_selector({selector => '.foo' });

=cut

sub delete_selector {
  my ($self,$params) = @_;

  $self->_check_object();

  #store the properties, potentially overwriting properties that were there
  $self->_get_ordered()->DELETE($$params{selector});

  return();
}

=pod

=item delete_property( params )

Delete a property from a specific selectors rules

This method requires you to pass in a params hash that contains scalar
css data. For example:

$self->delete_property({selector => '.foo', property => 'color' });

=back

=cut

sub delete_property {
  my ($self,$params) = @_;

  $self->_check_object();

  #get the properties so we can remove the requested property from the hash
  my $properties = $self->get_properties({selector => $$params{selector}});

  delete $$properties{$$params{property}};

  $self->add_selector({selector => $$params{selector}, properties => $properties});

  return();
}
  
####################################################################
#                                                                  #
# The following are all private methods and are not for normal use #
# I am working to finalize the get/set methods to make them public #
#                                                                  #
####################################################################

sub _check_object {
  my ($self,$params) = @_;

  unless ($self && ref $self) {
    die "You must instantiate this class in order to properly use it";
  }

  return();
}

sub _get_ordered {
  my ($self,$params) = @_;

  $self->_check_object();

  return($self->{ordered});
}

sub _report_error {
  my ($self,$params) = @_;

  $self->_check_object();

  if ($self->{suppress_errors}) {
    warn $$params{info};
  }
  else {
    die $$params{info};
  }

  return();
}

1;

=pod

=head1 Sponsor

This code has been developed under sponsorship of MailerMailer LLC, http://www.mailermailer.com/

=head1 AUTHOR

Kevin Kamel <C<kamelkev@mailermailer.com>>

=head1 ATTRIBUTION

This module is directly based off of Adam Kennedy's <adamk@cpan.org> CSS::Tiny module.

This particular version differs in terms of interface and the ultimate ordering of the CSS.

=head1 LICENSE

This module is a derived version of Adam Kennedy's CSS::Tiny Module.

This program is free software; you can redistribute it and/or modify it under the same terms as Perl itself.

The full text of the license can be found in the LICENSE file included with this module.

=cut
