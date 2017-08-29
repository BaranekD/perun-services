#!/usr/bin/perl

use strict;
use warnings;

use Getopt::Long qw(:config no_ignore_case);
use LWP::UserAgent;
use HTTP::Request;
use HTTP::Headers;
use JSON;
use Data::Dumper;

#We want to have data in UTF8 on output
binmode STDOUT, ':utf8';

#This also set Data Dumper to UTF8
local $Data::Dumper::Useqq = 1;
{ no warnings 'redefine';
	sub Data::Dumper::qquote {
		my $s = shift;
		return "'$s'";
	}
}

### Examples of possible commands with parameters
=c
./o365-connector.pl -s o365_mu -S develMU -c checkIfEmailExists -i jan@izydorczyk.cz
./o365-connector.pl -s o365_mu -S develMU -c getMuniContactByEmail -i jan@izydorczyk.cz
./o365-connector.pl -s o365_mu -S develMU -c getGroupByEmail -i test-lab-crocs@mandragora.onmicrosoft.com
./o365-connector.pl -s o365_mu -S develMU -c getO365GroupByEmail -i oss@ics.muni.cz
./o365-connector.pl -s o365_mu -S develMU -c getMuniMailboxByEmail -i 255920@mandragora.muni.cz
./o365-connector.pl -s o365_mu -S develMU -c getMuniShareboxByEmail -i jan@izydorczyk.cz
./o365-connector.pl -s o365_mu -S develMU -c setMuniGroup -i test-lab-crocs@mandragora.onmicrosoft.com -t 255920@mandragora.muni.cz 465818@mandragora.muni.cz
./o365-connector.pl -s o365_mu -S develMU -c setMuniMailbox -i 255920@mandragora.muni.cz -a 1 -d 0 -l "en-US" -f slavek@ics.muni.cz
=cut

#-----------------------------CONSTANTS------------------------------------
#DEBUG has 3 levels (0 = no debug, 1 = some important debug messages, 2 = all debug messages)
our $DEBUG=0;
#Maximum time to wait on server response (after that it tries the same time to get result)
#Time to get result is 2xMAX_WAIT_SEC sec
our $MAX_WAIT_SEC=20;
our $MAX_WAIT_MSEC = $MAX_WAIT_SEC * 1000;

#Mandatory settings to be able to call server as authorized user
our $URL;
our $USERNAME;
our $PASSWORD;
our $HOST;
our $PORT;
our $PSWS_HOST;

#All possible exceptions
our $ERROR_UNKNOWN_RETURNED_CODE      = "Unknown returned code get from status of call. This is an internal script error!\n";
our $ERROR_ISS_COM_PROBLEM            = "Communication problem with ISS server, before processing command itself!\n";
our $ERROR_WRONG_ISS_EXECUTION        = "Wrong executing on ISS server site, probably bad request!\n";
our $ERROR_O365_OR_PS_ERROR           = "Error on the site of o365 or PS scripts!\n";
our $ERROR_UNKNOWN_STATUS             = "Unknown status of call. We don't know how to process this one!\n";
our $ERROR_UNKNOWN_COMMAND            = "Unknown parameter command.\n";
our $ERROR_UNSUPPORTED_COMMAND        = "Unsupported command, we don't know how to resolve it!\n";
our $ERROR_UNSUPPORTED_COMMAND_STATUS = "Unsupported command status, we don't know how to resolve it!\n";
our $ERROR_MANDATORY_OBJECT_IS_EMPTY  = "Mandatory object in parameter of method is empty!\n";
our $ERROR_MISSING_PARAMETER          = "Manadatory parameter is missing!\n";
our $ERROR_OBJECT_NOT_FOUND           = "Object you are looking for not found by identifier!\n";
our $ERROR_CANNOT_FOUND_CONFIGURATION = "Configuration of REST server is missing, can't found it!\n";
our $ERROR_SET_METHOD_END_WITH_NOOK   = "Set method returned NoOK status!\n";
our $ERROR_HARD_TIMEOUT               = "Timeout expired!\n";

#Types of command processing
our $COMMAND_STATUS_SET = 'SET';
our $COMMAND_STATUS_RESOLVE = 'RESOLVE';

#All possible commands to call
our $COMMAND_PING_EMAIL = "checkIfEmailExists";
our $COMMAND_GET_CONTACT = "getMuniContactByEmail";
our $COMMAND_GET_GROUP = "getGroupByEmail";
our $COMMAND_GET_O365_GROUP = "getO365GroupByEmail";
our $COMMAND_GET_MAILBOX = "getMuniMailboxByEmail";
our $COMMAND_GET_SHAREBOX = "getMuniShareboxByEmail";
our $COMMAND_SET_GROUP = "setMuniGroup";
our $COMMAND_SET_MAILBOX = "setMuniMailbox";

#Basic content of every call
our %content = (
  "OutputFormat" => "json",
  "WaitMsec" => $MAX_WAIT_MSEC
);

#Global needed variables
our $actualCommand = "";
our $finalJsonOutput = {};

#Method with information about possible parameters of this script
sub help {
	return qq{
Call selected method to proceed on O365 REST API.
Return help + exit 1 if help is needed.
Return STDOUT + exit 0 if everything is ok.
Return STDERR + exit >0 if error happens.
Available commands with mandatory options:
 --command "$COMMAND_SET_MAILBOX" -i "emailOfMailbox" -a 1|0 -d 1|0 -l "language" -f "email"
 --command "$COMMAND_SET_GROUP" -i "nameOfGroup" -t contact1 contact2 ...
 --command "$COMMAND_PING_EMAIL" -i "emailToPing"
 --command "$COMMAND_GET_CONTACT" -i "nameOfContact"
 --command "$COMMAND_GET_GROUP" -i "nameOfGroup"
 --command "$COMMAND_GET_MAILBOX" -i "emailOfMailbox"
 --command "$COMMAND_GET_O365_GROUP" -i "nameOfGroup"
 --command "$COMMAND_GET_SHAREBOX" -i "emailOfSharebox"
---------------------------------------------------------
Other options:
 --help        | -h prints this help
All methods mandatory options:
 --serviceName | -s name of service for which we will be connecting server
 --serverName  | -S name of server to get authorization data for
 --command     | -c command to call
 --identifier  | -i main identifier of object (most often email)
SetMailbox mandatory options:
 --language    | -l language to use for mailbox, "en-US" is default
 --archiving   | -a enable or disable archiving, values 1=enable, 0=disable, disabled by default
 --delivering  | -d enable or disable delivering to mailbox, values 1=enable, 0=disable, disabled by default
 --forwarding  | -f forward to email address for mailing list
SetGroup mandatory options:
 --contacts    | -t list of contacts to be able to send email as group\n
};
}

#-------------------------------------------------------------------------
#----------------------------------MAIN CODE------------------------------
#-------------------------------------------------------------------------

#Get parameters of script and assign them to variables
my $inputCommand = $0;
foreach my $argument (@ARGV) { $inputCommand .= " " . $argument; }
my ($service, $server, $argIdent, $argCommand, $argLang, $argArch, $argDeliv, $argForw, @argContacts);
GetOptions("help|h"	=> sub {
		print help;
		exit 1;
	},
	"service|s=s"     => \$service,
	"server|S=s"      => \$server,
	"command|c=s"     => \$argCommand,
	"identifier|i=s"  => \$argIdent,
	"language|l=s"    => \$argLang,
	"archiving|a=i"   => \$argArch,
	"delivering|d=i"  => \$argDeliv,
	"forwarding|f=s"  => \$argForw,
	'contacts|t=s@{1,}' => \@argContacts ) || die help;

#Check existence of mandatory parameters
unless (defined $service) { diePretty ( $ERROR_MISSING_PARAMETER, "Service is required parameter\n" ); }
unless (defined $server) { diePretty ( $ERROR_MISSING_PARAMETER, "Server is required parameter\n" ); }
unless (defined $argCommand) { diePretty ( $ERROR_MISSING_PARAMETER, "Command is required parameter\n" ); }
unless (defined $argIdent) { diePretty ( $ERROR_MISSING_PARAMETER, "Identifier is required parameter\n" ); }

#Read configuration form configuration file
my $configPath = "/etc/perun/services/$service/$server";
open FILE, $configPath or die "Could not open config file $configPath: $!";
while(my $line = <FILE>) {
	chomp( $line );
	if($line =~ /^username: .*/) {
		$USERNAME = ($line =~ /^username: (.*)$/)[0];
	} elsif($line =~ /^password: .*/) {                                                         
		$PASSWORD = ($line =~ /^password: (.*)$/)[0];
	} elsif($line =~ /^url: .*/) {
		$URL = ($line =~ /^url: (.*)$/)[0];
	} elsif($line =~ /^host: .*/) {
		$HOST = ($line =~ /^host: (.*)$/)[0];
	} elsif($line =~ /^port: .*/) {
		$PORT = ($line =~ /^port: (.*)$/)[0];
	}
}

#Check mandatory configuration
if(!defined($PASSWORD) || !defined($USERNAME) || !defined($URL) || !defined($HOST) || !defined($PORT)) {
	diePretty ( $ERROR_CANNOT_FOUND_CONFIGURATION, "Path to find: $configPath \n" );
}

#Choose and set command by parameter
if($argCommand eq $COMMAND_SET_MAILBOX) {
	unless (defined $argArch) { $argArch = 0; }
	unless (defined $argDeliv) { $argDeliv = 0; }
	unless (defined $argLang) { $argLang = "en-US"; }
	setMailbox ( $COMMAND_STATUS_SET, undef, $argIdent, $argDeliv, $argArch, $argForw, $argLang );
} elsif ($argCommand eq $COMMAND_SET_GROUP) {
	setGroup ( $COMMAND_STATUS_SET, undef, $argIdent, \@argContacts);
} elsif ($argCommand eq $COMMAND_PING_EMAIL) {
	pingEmail ( $COMMAND_STATUS_SET, undef, $argIdent);	
} elsif ($argCommand eq $COMMAND_GET_CONTACT) {
	getContact ( $COMMAND_STATUS_SET, undef, $argIdent );	
} elsif ($argCommand eq $COMMAND_GET_GROUP) {
	getGroup ( $COMMAND_STATUS_SET, undef, $argIdent);	
} elsif ($argCommand eq $COMMAND_GET_MAILBOX) {
	getMailbox ( $COMMAND_STATUS_SET, undef, $argIdent);	
} elsif ($argCommand eq $COMMAND_GET_O365_GROUP) {
	getO365Group ( $COMMAND_STATUS_SET, undef, $argIdent);	
} elsif ($argCommand eq $COMMAND_GET_SHAREBOX) {
	getSharebox ( $COMMAND_STATUS_SET, undef, $argIdent);	
} else {
	diePretty ( $ERROR_UNKNOWN_COMMAND, "Unknown command $argCommand!\n");
}

#Start calling and return result or die
my $jsonResult = startSession();
if($jsonResult) { print JSON->new->utf8->encode( $jsonResult ); }

#End with 0 if everything goes well
exit 0;

#-------------------------------------------------------------------------
#------------------------------COMMAND-SUBS-------------------------------
#-------------------------------------------------------------------------

#Name:
# setGroup
#-----------------------
#Parameters: 
# status     - status of command, do we want to set this command or resolve it
# jsonOutput - json output from the server as hash in perl, undef if there is no such output yet
# groupEmail - identifier of group in o365
# sendAs     - list of contacts which can use this group as own mail
#-----------------------
#Returns: void with exit status 0 = OK, error with exit status > 0 = not OK
#-----------------------
#Description: 
# For existing group in o365 set all possible addresses, which can use this group mail as it's own.
#-----------------------
sub setGroup {
	my $status = shift;
	my $jsonOutput = shift;
	my $groupEmail = shift;
	my $sendAs = shift;

	if(defined($jsonOutput->{"ErrorType"})) {
		diePretty ( $ERROR_O365_OR_PS_ERROR , "Some HARD internal message error in method call -> " . $jsonOutput->{"ErrorMessage"} . "\n" );
	}

	if($status eq $COMMAND_STATUS_SET) {
		$actualCommand = $COMMAND_SET_GROUP;
		unless($groupEmail) { diePretty ( $ERROR_MANDATORY_OBJECT_IS_EMPTY, "To set command $actualCommand we need to have not empty group email object!\n") };
		unless($sendAs) { $sendAs = []; }
		my $group = ();
		$group->{'groupName'} = $groupEmail;
		$group->{'sendAs'} = $sendAs;
		my $jsonGroup = JSON->new->utf8->encode( $group );
		$content{"Command"} = "Set-MuniGroup -DataJson '$jsonGroup'";
		return 1;
	} elsif ($status eq $COMMAND_STATUS_RESOLVE) {
		if($jsonOutput->{'Status'} eq 'OK') {
			return 0;
		} else {
			diePretty ( $ERROR_SET_METHOD_END_WITH_NOOK, "Status of output is: " . $jsonOutput->{'Status'} . "\n" );
		}
	} else {
		diePretty ( $ERROR_UNSUPPORTED_COMMAND_STATUS, "Unsupported status $status\n" );
	}
}

#Name: 
# setMailbox
#-----------------------
#Parameters:
# status           - status of command, do we want to set this command or resolve it
# json output      - json output from the server as hash in perl, undef if there is no such output yet
# upn              - identifier of user in o365 (email)
# deliverToMailbox - if delivering is set to true or false
# archive          - if archiving is set to true or false
# forwardTo        - address for forwaring all emails to
# language         - o365 mailbox language
#-----------------------
#Returns: void with exit status 0 = OK, error with exit status > 0 = not OK
#-----------------------
#Description: 
# For existing mailbox in o365 set some parameters.
#-----------------------
sub setMailbox {
	my $status = shift;
	my $jsonOutput = shift;
	my $upn = shift;
	my $deliverToMailbox = shift;
	my $archive = shift;
	my $forwardTo = shift;
	my $language = shift;

	if(defined($jsonOutput->{"ErrorType"})) {
		diePretty ( $ERROR_O365_OR_PS_ERROR , "Some HARD internal message error in method call -> " . $jsonOutput->{"ErrorMessage"} . "\n" );
	}

	if($status eq $COMMAND_STATUS_SET) {
		$actualCommand = $COMMAND_SET_MAILBOX;
		unless($upn) { diePretty ( $ERROR_MANDATORY_OBJECT_IS_EMPTY, "To set command $actualCommand we need to have not empty user identifier object!\n") };
		my $user = ();
		$user->{'upn'} = $upn;
		$user->{'language'} = $language;
		$user->{'forwardingSmtpAddress'} = $forwardTo ? $forwardTo : JSON::null;
		$user->{'deliverToMailboxAndForward'} = $deliverToMailbox ? JSON::true : JSON::false;
		$user->{'archive'} = $archive ? JSON::true : JSON::false;
		my $jsonUser = encode_json( $user );
		$content{"Command"} = "Set-MuniMailbox -DataJson '$jsonUser'";
		return 1;
	} elsif ($status eq $COMMAND_STATUS_RESOLVE) {
		if($jsonOutput->{'Status'} eq 'OK') {
			return 0;
		} else {
			diePretty ( $ERROR_SET_METHOD_END_WITH_NOOK, "Status of method  output is: " . $jsonOutput->{'Status'} . "\n" );
		}
	} else {
		diePretty ( $ERROR_UNSUPPORTED_COMMAND_STATUS, "Unsupported status $status\n" );
	}
}

#Name:
# getSharebox
#-----------------------
#Parameters: 
# status     - status of command, do we want to set this command or resolve it
# jsonOutput - json output from the server as hash in perl, undef if there is no such output yet
# email      - identifier of sharebox email address in o365
#-----------------------
#Returns: JSON object sharebox with specific parameters and exit status 0 = OK, error with exit status > 0 = not OK
#-----------------------
#Description: 
# Get json object sharebox by identifier if exists in o365.
#-----------------------
sub getSharebox {
	my $status = shift;
	my $jsonOutput = shift;
	my $email = shift;

	if(defined($jsonOutput->{"ErrorType"})) {
		diePretty ( $ERROR_O365_OR_PS_ERROR , "Some HARD internal message error in method call -> " . $jsonOutput->{"ErrorMessage"} . "\n" );
	}

	if($status eq $COMMAND_STATUS_SET) {
		$actualCommand = $COMMAND_GET_SHAREBOX;
		unless($email) { diePretty ( $ERROR_MANDATORY_OBJECT_IS_EMPTY, "To set command $actualCommand we need to have not empty email object!\n") };
		$content{"Command"} = "Get-MuniSharedMailbox $email -property '*'";
		return 1;
	} elsif ($status eq $COMMAND_STATUS_RESOLVE) {
		unless($jsonOutput) { diePretty ( $ERROR_MANDATORY_OBJECT_IS_EMPTY, "To resolve command $actualCommand we need to have not empty JSON output object!\n") };
		return $jsonOutput;
	} else {
		diePretty ( $ERROR_UNSUPPORTED_COMMAND_STATUS, "Unsupported status $status\n" );
	}
}

#Name:
# getMailbox
#-----------------------
#Parameters: 
# status     - status of command, do we want to set this command or resolve it
# jsonOutput - json output from the server as hash in perl, undef if there is no such output yet
# email      - identifier of mailbox email address in o365
#-----------------------
#Returns: JSON object mailbox with specific parameters and exit status 0 = OK, error with exit status > 0 = not OK
#-----------------------
#Description: 
# Get json object mailbox by identifier if exists in o365.
#-----------------------
sub getMailbox {
	my $status = shift;
	my $jsonOutput = shift;
	my $email = shift;

	if(defined($jsonOutput->{"ErrorType"})) {
		diePretty ( $ERROR_O365_OR_PS_ERROR , "Some HARD internal message error in method call -> " . $jsonOutput->{"ErrorMessage"} . "\n" );
	}

	if($status eq $COMMAND_STATUS_SET) {
		$actualCommand = $COMMAND_GET_MAILBOX;
		unless($email) { diePretty ( $ERROR_MANDATORY_OBJECT_IS_EMPTY, "To set command $actualCommand we need to have not empty email object!\n") };
		$content{"Command"} = "Get-MuniMailbox $email -property 'forwardingSmtpAddress,deliverToMailboxAndForward,ArchiveStatus,Languages,userprincipalname'";
		return 1;
	} elsif ($status eq $COMMAND_STATUS_RESOLVE) {
		unless($jsonOutput) { diePretty ( $ERROR_MANDATORY_OBJECT_IS_EMPTY, "To resolve command $actualCommand we need to have not empty JSON output object!\n") };
		return $jsonOutput;
	} else {
		diePretty ( $ERROR_UNSUPPORTED_COMMAND_STATUS, "Unsupported status $status\n" );
	}
}

#Name:
# getGroup
#-----------------------
#Parameters: 
# status     - status of command, do we want to set this command or resolve it
# jsonOutput - json output from the server as hash in perl, undef if there is no such output yet
# email      - identifier of group email address in o365
#-----------------------
#Returns: JSON object group with specific parameters and exit status 0 = OK, error with exit status > 0 = not OK
#-----------------------
#Description: 
# Get json object group by identifier if exists in o365.
#-----------------------
sub getGroup {
	my $status = shift;
	my $jsonOutput = shift;
	my $email = shift;

	if(defined($jsonOutput->{"ErrorType"})) {
		diePretty ( $ERROR_O365_OR_PS_ERROR , "Some HARD internal message error in method call -> " . $jsonOutput->{"ErrorMessage"} . "\n" );
	}

	if($status eq $COMMAND_STATUS_SET) {
		$actualCommand = $COMMAND_GET_GROUP;
		unless($email) { diePretty ( $ERROR_MANDATORY_OBJECT_IS_EMPTY, "To set command $actualCommand we need to have not empty email object!\n") };
		$content{"Command"} = "Get-MuniGroup $email -property 'EmailAddresses, members, TrusteeSendAs'";
		return 1;
	} elsif ($status eq $COMMAND_STATUS_RESOLVE) {
		unless($jsonOutput) { diePretty ( $ERROR_MANDATORY_OBJECT_IS_EMPTY, "To resolve command $actualCommand we need to have not empty JSON output object!\n") };
		return $jsonOutput;
	} else {
		diePretty ( $ERROR_UNSUPPORTED_COMMAND_STATUS, "Unsupported status $status\n" );
	}
}

#Name:
# getO365Group
#-----------------------
#Parameters: 
# status     - status of command, do we want to set this command or resolve it
# jsonOutput - json output from the server as hash in perl, undef if there is no such output yet
# email      - identifier of O365Group email address in o365 (special group type different from normal group)
#-----------------------
#Returns: JSON object O365Group with specific parameters and exit status 0 = OK, error with exit status > 0 = not OK
#-----------------------
#Description: 
# Get json object O365Group by identifier if exists in o365.
#-----------------------

sub getO365Group {
	my $status = shift;
	my $jsonOutput = shift;
	my $email = shift;

	if(defined($jsonOutput->{"ErrorType"})) {
		diePretty ( $ERROR_O365_OR_PS_ERROR , "Some HARD internal message error in method call -> " . $jsonOutput->{"ErrorMessage"} . "\n" );
	}

	if($status eq $COMMAND_STATUS_SET) {
		$actualCommand = $COMMAND_GET_O365_GROUP;
		unless($email) { diePretty ( $ERROR_MANDATORY_OBJECT_IS_EMPTY, "To set command $actualCommand we need to have not empty email object!\n") };
		$content{"Command"} = "Get-MuniGroup $email -property 'EmailAddresses, members'";
		return 1;
	} elsif ($status eq $COMMAND_STATUS_RESOLVE) {
		unless($jsonOutput) { diePretty ( $ERROR_MANDATORY_OBJECT_IS_EMPTY, "To resolve command $actualCommand we need to have not empty JSON output object!\n") };
		return $jsonOutput;
	} else {
		diePretty ( $ERROR_UNSUPPORTED_COMMAND_STATUS, "Unsupported status $status\n" );
	}
}

#Name:
# pingEmail
#-----------------------
#Parameters: 
# status     - status of command, do we want to set this command or resolve it
# jsonOutput - json output from the server as hash in perl, undef if there is no such output yet
# email      - identifier of email address in o365
#-----------------------
#Returns: void and exit status 0 = OK, error with exit status > 0 = not OK
#-----------------------
#Description: 
# Information about existence specific email in o365.
#-----------------------
sub pingEmail {
	my $status = shift;
	my $jsonOutput = shift;
	my $email = shift;

	if(defined($jsonOutput->{"ErrorType"})) {
		diePretty ( $ERROR_O365_OR_PS_ERROR , "Some HARD internal message error in method call -> " . $jsonOutput->{"ErrorMessage"} . "\n" );
	}

	if($status eq $COMMAND_STATUS_SET) {
		unless($email) { diePretty ( $ERROR_MANDATORY_OBJECT_IS_EMPTY, "To set command $actualCommand we need to have not empty email object!\n") };
		$actualCommand = $COMMAND_PING_EMAIL;
		$content{"Command"} = "ping-muniemailaddress $email -short";
		return 1;
	} elsif ($status eq $COMMAND_STATUS_RESOLVE) {
		unless($jsonOutput) { diePretty ( $ERROR_MANDATORY_OBJECT_IS_EMPTY, "To resolve command $actualCommand we need to have not empty JSON output object!\n") };
		my $emailExists = $jsonOutput->{'EmailExists'};
		if($emailExists eq 'True') {
			if($DEBUG>0) { print "Email exists in the system!\n"; }
			return 0;
		} else {
			if($DEBUG>0) { print "Email NOT exists in the system!\n"; }
			diePretty ( $ERROR_OBJECT_NOT_FOUND, "Email not exists in the system!\n" );
		}
	} else {
		diePretty ( $ERROR_UNSUPPORTED_COMMAND_STATUS, "Unsupported status $status\n" );
	}
}

#Name:
# getContact
#-----------------------
#Parameters: 
# status     - status of command, do we want to set this command or resolve it
# jsonOutput - json output from the server as hash in perl, undef if there is no such output yet
# email      - identifier of email concatc address (user) in o365
#-----------------------
#Returns: JSON object contact with specific parameters and exit status 0 = OK, error with exit status > 0 = not OK
#-----------------------
#Description: 
# Get json object contact by identifier if exists in o365.
#-----------------------
sub getContact {
	my $status = shift;
	my $jsonOutput = shift;
	my $email = shift;

	if(defined($jsonOutput->{"ErrorType"})) {
		diePretty ( $ERROR_O365_OR_PS_ERROR , "Some HARD internal message error in method call -> " . $jsonOutput->{"ErrorMessage"} . "\n"  );
	}

	if($status eq $COMMAND_STATUS_SET) {
		unless($email) { diePretty ( $ERROR_MANDATORY_OBJECT_IS_EMPTY, "To set command $actualCommand we need to have not empty email object!\n") };
		$actualCommand = $COMMAND_GET_CONTACT;
		$content{"Command"} = "Get-MuniContact $email -property 'DisplayName,EmailAddress'";
		return 1;
	} elsif ($status eq $COMMAND_STATUS_RESOLVE) {
		unless($jsonOutput) { diePretty ( $ERROR_MANDATORY_OBJECT_IS_EMPTY, "To resolve command $actualCommand we need to have not empty JSON output object!\n") };
		return $jsonOutput;
	} else {
		diePretty ( $ERROR_UNSUPPORTED_COMMAND_STATUS, "Unsupported status $status\n" );
	}
}

#-------------------------------------------------------------------------
#-----------------------------------SUBS----------------------------------
#-------------------------------------------------------------------------

#Name:
# startSession
#-----------------------
#Parameters: 
# There is no parameter, but one of commands need to be set before calling this method.
#-----------------------
#Returns: result of calling if any exists in hash structure (as json format)
#         exit status 0 means everything is OK, die in any other situation
#-----------------------
#Description: 
# This method starts whole session of calling o365 REST API.
# It takes care about maximum waiting time to get answer for server.
# After timeout, it ends with error.
#-----------------------
sub startSession {
	my $sessionNumber = int rand(1000000);
	if($DEBUG>0) { 
		print "#######################################################################################\n";
		print "Session number $sessionNumber: START\n"; 
	}
	#First call of command
	my $urlToRepeat = callServer( $URL, 'POST', \%content );

	#When there is something nasty (soft error or maxwait) then repeat till error or done
	my $waitingInSec = 0;
	while($urlToRepeat) {
		if($waitingInSec == $MAX_WAIT_SEC) { diePretty ( $ERROR_HARD_TIMEOUT , "Timeout was longer than 2x$MAX_WAIT_SEC seconds.\n"); };
		if($urlToRepeat eq $URL) {
			#Problem with soft error
			if($DEBUG>0) { print "Need to repeat calling because of soft error: $urlToRepeat\n"; }
			$urlToRepeat = callServer( $urlToRepeat, 'POST', \%content );
		} else {
			#Problem with executing state
			if($DEBUG>0) { print "Need to repeat calling because of timeout on execution maxWait: $urlToRepeat\n"; }
			sleep 1;
			$urlToRepeat = callServer( $urlToRepeat, 'GET', {} );
		}
		$waitingInSec++;
	}

	my $result = resolveOutputByCommandName ( $finalJsonOutput );
	if($DEBUG>0) { print "RESULT IS: " . Dumper($result); }

	#everything is ok
	if($DEBUG>0) { 
		print "Session number $sessionNumber: DONE SUCCESSFULLY\n"; 
		print "#######################################################################################\n";
	}

	return $result;
}

#Name:
# callServer
#-----------------------
#Parameters: 
# url     - url of server and method address to call
# type    - GET or PUT
# content - hash content of request, will be encoded to json output
#-----------------------
#Returns: 
# resolved status of call
# 0 means everything is ok and done
# text means URL address to call again (because of soft error or maxwait timeout)
# die in other case (hard error, server error or other error)
#-----------------------
#Description: 
# This method calls specific url with get or put connection type and predefined content in json.
# After that it check response, if there is correct answer or error.
# If there is no server error, it returns resolved status of this call.
#-----------------------
sub callServer {
	my $url = shift;
	my $type = shift;
	my $content = shift;

	my $serverResponse = createConnection( $url, $type, JSON->new->utf8->encode( $content ) );
	my $serverResponseJson = checkServerResponse( $serverResponse );
	#Just for debug purposes print whole information about json object
	printJsonOutput( $serverResponseJson );
	return resolveStatusOfCall( $serverResponseJson );
}

#Name:
# createConnection
#-----------------------
#Parameters: 
# url     - url of server and method address to call
# type    - GET or PUT
# content - hash content of request, will be encoded to json output
#-----------------------
#Returns: Response of server on our request.
#-----------------------
#Description: 
# This method just takes all parameters and creates connection to the server.
# Then returns it's repsonse.
#-----------------------
sub createConnection {
	my $url = shift;
	my $type = shift;
	my $content = shift;

	my $address = $HOST . ":" . $PORT;
	my $domain = $HOST;
	
	my $headers = HTTP::Headers->new;
	$headers->header('Content-Type' => 'application/json');
	$headers->header('Accept' => 'application/json,text/json');

	my $ua = LWP::UserAgent->new;
	$ua->credentials( $address, $domain, $USERNAME, $PASSWORD ); 
	my $request = HTTP::Request->new( $type, $url, $headers, $content );

	return $ua->request($request);
}

#Name:
# checkServerResponse
#-----------------------
#Parameters: 
# response - response from server in JSON format
#-----------------------
#Returns: decoded json respons if response is success, die if response of server is not success
#-----------------------
#Description: 
# This method checks if response of server was success. If yes, return decoded json response,
# if not, die with error.
#-----------------------
sub checkServerResponse {
	my $response = shift;
	my $responseJson;

	if ($response->is_success) {
		$PSWS_HOST = $response->header( "psws-host" );
		$responseJson = JSON->new->utf8->decode( $response->content );
	} else {
		my $responseInfo = $response->status_line . "\n" . $response->decoded_content . "\n";
		diePretty( $ERROR_ISS_COM_PROBLEM, $responseInfo ); 
	}
	return $responseJson;
}

#Name:
# getOutputInJson
#-----------------------
#Parameters: 
# responseJson = server response in decoded json format (hash in perl)
#-----------------------
#Returns: decoded json output (part of response of the server - there is json output as part of json response)
#-----------------------
#Description: 
# Parse and return json output (if any exists) from the server response
#-----------------------
sub getOutputInJson {
	my $responseJson = shift;
	my $outputJson = {};
	if ($responseJson->{'Output'}) { 
		$outputJson = JSON->new->decode( $responseJson->{'Output'} ); 
	} 
	return $outputJson; 
}

#Name:
# printJsonOutput
#-----------------------
#Parameters: 
# responseJson - decoded response from server (hash in perl)
#-----------------------
#Returns:
# void
#-----------------------
#Description: 
# This method is only for information purpose (debuging).
# It prints all interesting information from server response (including json output)
#-----------------------
sub printJsonOutput {
	my $responseJson = shift;
	if($DEBUG<2) { return 1 };

	my $outputJson = getOutputInJson( $responseJson );

	print "\n------------------------------------------\n";
	print "RESPONSE:\n";
	print "------------------------------------------\n";
	print "COMMAND = " . $responseJson->{'Command'} . "\n";
	print "HOST    = " . $HOST . "\n";
	print "PSWS_HOST = " . $PSWS_HOST . "\n";
	print "URL     = " . $URL . "\n";
	print "STATUS  = " . $responseJson->{'Status'} . "\n";
	print "ERRORS  = " . Dumper($responseJson->{'Errors'});
	print "FORMAT  = " . $responseJson->{'OutputFormat'} . "\n";
	print "OUTPUT  = " . Dumper($outputJson);
	print "-------------------------------------------\n\n";
}

#Name:
# checkStatusOfCall
#-----------------------
#Parameters: 
# responseJson - server decoded json response (hash in perl)
#-----------------------
#Returns:
# "ERROR" if there is some server error in response
# "HARD"  if there hard application error in response
# "SOFT"  if there is only soft application error in response (we should try calling again after some time)
# "OK"    if no errors are in server response, everything shoudl be ok
#-----------------------
#Description: 
# This method checks if there is any error in the server response.
#-----------------------
sub checkStatusOfCall {
	my $responseJson = shift;
	my $SERVER_ERR = "ERROR";
	my $SOFT_ERR = "SOFT";
	my $HARD_ERR = "HARD";
	my $STATUS_OK = "OK";

	my $outputJson = getOutputInJson( $responseJson );
	if ($responseJson->{'Output'}) { $outputJson = JSON->new->decode($responseJson->{'Output'}); }

	if(@{$responseJson->{'Errors'}}) {
		return $SERVER_ERR;
	}

	if($outputJson->{"ErrorType"}) {
		if($outputJson->{"ErrorType"} eq $SOFT_ERR) {
			return $SOFT_ERR;
		} else {
			return $HARD_ERR;
		}
	}
	
	return $STATUS_OK;
}

#Name:
# resolveStatusOfCall
#-----------------------
#Parameters: 
# responseJson - server decoded json response (hash in perl)
#-----------------------
#Returns:
# If There is no error and task was completed - return 0
# If there is no error, but task is still in execution - return URL to check status of call
# If there is some soft application error - return URL to try call again
# If there is some server error - die 
# If there is some hard application error - die
#-----------------------
#Description: 
# This method checks and then resolve status of server response.
# If there is need to check status again or repeat calling, it return url address for this purpose.
#-----------------------
sub resolveStatusOfCall {
	my $responseJson = shift;

	my $returnedCode = checkStatusOfCall( $responseJson );

	if($returnedCode eq "OK") {
		if($responseJson->{'Status'} eq 'Completed') {
			$finalJsonOutput = getOutputInJson( $responseJson );
			return 0;
		} elsif ($responseJson->{'Status'} eq 'Executing') {
			my $newURL = $URL;
			if($HOST ne $PSWS_HOST) {
				$HOST = $PSWS_HOST;
				$newURL =~ s/$HOST/$PSWS_HOST/g;
			}
			return $newURL . "(guid'" . $responseJson->{"ID"} . "')";
		} else {
			diePretty( $ERROR_UNKNOWN_STATUS, "Unknown status = " . $responseJson->{'Status'} . "\n" ) ;
		}
	} elsif( $returnedCode eq "ERROR" ) {
		diePretty( $ERROR_WRONG_ISS_EXECUTION, Dumper($responseJson->{'Errors'}) . "\n" );
	}	elsif ($returnedCode eq "SOFT" ) {
			return $URL;
	} elsif ($returnedCode eq "HARD" ) {
		$finalJsonOutput = getOutputInJson( $responseJson );
		return 0;
	} else {
		diePretty( $ERROR_UNKNOWN_RETURNED_CODE, "No more info, internal Error.\n" );
	}
}

#Name:
# diePretty
#-----------------------
#Parameters: 
# errorMessage  - basic error information (one of predefined errors)
# moreErrorInfo - more specific information about basic error
#-----------------------
#Returns:
#-----------------------
#Description: 
# This is just exit with error with more information and human readable text formating.
#-----------------------
sub diePretty {
	my $errorMessage = shift;
	my $moreErrorInfo = shift;
	my $rowDelimeter = "------------------------------------------------------------------------\n";
	my $status =       "               STATUS = ERROR\n";
	my $forCommand = "INPUT COMMAND: " . $inputCommand . "\n";

	$errorMessage = $rowDelimeter . $status . $rowDelimeter . $errorMessage . $rowDelimeter . $moreErrorInfo  . $rowDelimeter . $forCommand . $rowDelimeter;

	die $errorMessage;
}

#Name:
# resolveOtuputByCommandName
#-----------------------
#Parameters: 
# jsonOutput - decoded json output from server response (hash in perl)
#-----------------------
#Returns:
# output of choosed command method with resolve status
#-----------------------
#Description: 
# This method just call resolving on specific method defined by choosed command.
# It returns output of one of these methods or die if such command is not known yet.
#-----------------------
sub resolveOutputByCommandName {
	my $jsonOutput = shift;	
	if($actualCommand eq $COMMAND_PING_EMAIL) {
		return pingEmail( $COMMAND_STATUS_RESOLVE, $jsonOutput );
	} elsif ($actualCommand eq $COMMAND_GET_CONTACT) {
		return getContact ( $COMMAND_STATUS_RESOLVE, $jsonOutput );
	} elsif ($actualCommand eq $COMMAND_GET_O365_GROUP) {
		return getO365Group ( $COMMAND_STATUS_RESOLVE, $jsonOutput );
	} elsif ($actualCommand eq $COMMAND_GET_GROUP) {
		return getGroup ( $COMMAND_STATUS_RESOLVE, $jsonOutput );
	} elsif ($actualCommand eq $COMMAND_GET_SHAREBOX) {
		return getSharebox ( $COMMAND_STATUS_RESOLVE, $jsonOutput );
	} elsif ($actualCommand eq $COMMAND_GET_MAILBOX) {
		return getMailbox ( $COMMAND_STATUS_RESOLVE, $jsonOutput );
	} elsif ($actualCommand eq $COMMAND_SET_GROUP) {
		return setGroup ( $COMMAND_STATUS_RESOLVE, $jsonOutput );
	} elsif ($actualCommand eq $COMMAND_SET_MAILBOX) {
		return setMailbox ( $COMMAND_STATUS_RESOLVE, $jsonOutput );
	} else {
		diePretty( $ERROR_UNSUPPORTED_COMMAND, "Command with number $actualCommand not known.\n" );
	}
}
