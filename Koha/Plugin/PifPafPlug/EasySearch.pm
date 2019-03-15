package Koha::Plugin::PifPafPlug::EasySearch;

## It's good practive to use Modern::Perl
use Modern::Perl;
## Required for all plugins
use base qw(Koha::Plugins::Base);
## We will also need to include any Koha libraries we want to access
use File::Basename;
use Koha::Items;

## Here we set our plugin version
our $VERSION = 20;

## Here is our metadata, some keys are required, some are optional
our $metadata = {
    name   => 'EasySearch',
    author => 'Olivier Crouzet',
    description =>'This plugin allows via Koha installing search plugins in Firefox',
    date_authored   => '2017-01-06',
    date_updated    => '2017-04-13',
    minimum_version => '3.18',
    maximum_version => undef,
    version         => $VERSION,
};

## This is the minimum code required for a plugin's 'new' method
## More can be added, but none should be removed
sub new {
    my ( $class, $args ) = @_;

    ## We need to add our metadata here so our base class can access it
    $args->{'metadata'} = $metadata;
    $args->{'metadata'}->{'class'} = $class;

    ## Here, we call the 'new' method for our base class
    ## This runs some additional magic and checking
    ## and returns our actual $self
    my $self = $class->SUPER::new($args);

    return $self;
}

## The existance of a 'tool' subroutine means the plugin is capable
## of running a tool. The difference between a tool and a report is
## primarily semantic, but in general any plugin that modifies the
## Koha database should be considered a tool
sub tool {
    my ( $self, $args ) = @_;
    my $cgi = $self->{'cgi'};

    if ( $cgi->param('edititem')) {
        # Redirect barcode or stocknumber query so as to reach directly edit item page
        my $barcode = $cgi->param('barcode');
        my $stocknumber = $cgi->param('stocknumber');
        my $refnumber = $barcode ? $barcode : $stocknumber;
        my $dbh = C4::Context->dbh;
        my $query = "SELECT itemnumber from items where ";
        $query.= $barcode ? "barcode = ?":"stocknumber = ?";
        my $sth = $dbh->prepare($query);
        $sth->execute($refnumber);
        my ($itemnumber) = $sth->fetchrow();

        if (!defined($itemnumber)){
            print $cgi->redirect("/cgi-bin/koha/catalogue/search.pl?q=$refnumber");
            exit;
        } else {
            my $item = Koha::Items->find( $itemnumber );
            my $biblionumber = $item ? $item->biblio->biblionumber : undef;
            print $cgi->redirect("/cgi-bin/koha/cataloguing/additem.pl?op=edititem&biblionumber=$biblionumber&itemnumber=$itemnumber");
            exit;
        }
    }
    else {
        $self->tool_step1();
    }

}

## If your tool is complicated enough to needs it's own setting/configuration
## you will want to add a 'configure' method to your plugin like so.
## Here I am throwing all the logic into the 'configure' method, but it could
## be split up like the 'report' method is.
sub configure {

    my ( $self, $args ) = @_;
    my $cgi = $self->{'cgi'};

    if ( $cgi->param('saveconfig') ) {
        # Save config in database
        my @reftypes = $cgi->multi_param("reftype");
        my @reflabels = $cgi->multi_param("reflabel");
        my @alterservers = $cgi->multi_param("alterserver");
        my @refqueries = $cgi->multi_param("refquery");
        my $refquery =  join (',', $cgi->multi_param("refquery"));
        $refquery =~ s/&/&amp;/g;
        my @iconurls = $cgi->multi_param("iconurl");
        my $kohaserver = $cgi->param("kohaserver");
        my $params = {
            'kohaserver'  => $kohaserver,
            'reftype'     => join (',',@reftypes),
            'reflabel'    => join (',',@reflabels),
            'alterserver' => join (',',@alterservers),
            'refquery'    => $refquery,
            'iconurl'     => join (',',$cgi->param("iconurl")),
        };
        $self->store_data($params);
        
        # Create xml opensearch plugin directory and files
        my $dirname = dirname(__FILE__);
        my $searchplugpath = $dirname.'/EasySearch/searchplugins/';
        mkdir $searchplugpath unless -d $searchplugpath;
        
        my $template = $self->get_template({ file => 'searchplugin.tt' });

        foreach ( 0..$#reftypes ) {
            $refqueries[$_] =~ s/&/&amp;/g;
            my $server = ($alterservers[$_] and $alterservers[$_] ne $kohaserver) ? $alterservers[$_] : $kohaserver;
            my $url = $server.$refqueries[$_];
            my $iconurl = $kohaserver.$iconurls[$_];
            $template->param( 'shortname' => $reflabels[$_],
                              'url' => => $url,
                              'iconurl' => $iconurl,
                            );
            my $xmlfile = $reftypes[$_].'.xml';
            open my $fh,'>:encoding(UTF-8)',$searchplugpath.$xmlfile;
            print $fh $template->output();
            close $fh;
        }
        
    }
    elsif ( $cgi->param('savemenu') ) {
        my $tooltip = $cgi->param('tooltip');
        my $menu = $cgi->param('menu');

        my @checkedplugs = $cgi->multi_param("checkedplug");
        my $checkedplug = join(',',@checkedplugs);
        my $params = { 'tooltip' => $tooltip, 'menu' => $menu, 'checkedplug' => $checkedplug, };
        $self->store_data($params);
        my @reftypes = split ',',$self->retrieve_data("reftype");
        my @reflabels = split ',',$self->retrieve_data("reflabel");
    
        # Build javascript for menulist of searchplugins to be displayed on top menu bar
        my $jstemplate = $self->get_template({ file => 'updateIntranetJS.tt' });
        my $searchplugins;
        foreach ( 0..$#reftypes ) {
            next unless $checkedplugs[$_];
            push @$searchplugins, {
                "reftype" => $reftypes[$_],
                "reflabel" => $reflabels[$_],
            };
        }
        $jstemplate->param( 'searchplugins' => $searchplugins,
                      'tooltip' => $tooltip,
                      'menu' => $menu,
                      'searchplug_webdir' => "/plugin/Koha/Plugin/PifPafPlug/EasySearch/searchplugins/",
                    );    
        my $pluginlist_js = $jstemplate->output();
        my $intranetuserjs = C4::Context->preference('intranetuserjs');
        $intranetuserjs =~ s!\/\* Koha EasySearch Plugin.*End of Koha EasySearch Plugin \*\/!!s;
        $pluginlist_js = qq|\n/* Koha EasySearch Plugin */\n|.$pluginlist_js.qq|\n/* End of Koha EasySearch Plugin */|;
        $intranetuserjs.=$pluginlist_js;
        C4::Context->set_preference( 'intranetuserjs', $intranetuserjs );
    }
    elsif ( $cgi->param('remove') ) {
        my $intranetuserjs = C4::Context->preference('intranetuserjs');
        $intranetuserjs =~ s!\/\* Koha EasySearch Plugin.*End of Koha EasySearch Plugin \*\/!!s;
        C4::Context->set_preference( 'intranetuserjs', $intranetuserjs );
        C4::Context->dbh->do("delete from plugin_data where plugin_class='Koha::Plugin::PifPafPlug::EasySearch' and plugin_key in ('menu','tooltip','checkedplug')");
    }
    
    my $template = $self->get_template({ file => 'configure.tt' });

    ## Grab the values we already have for our settings, if any exist
    my $kohaserver = $self->retrieve_data("kohaserver");
    # Plugin parameters from same type are stocked in database as a single string. Split them
    my @reftypes = split /,/, $self->retrieve_data("reftype");
    my @reflabels = split /,/, $self->retrieve_data("reflabel");
    my @alterservers = split /,/, $self->retrieve_data("alterserver");
    my @refqueries = split /,/, $self->retrieve_data("refquery");
    my @iconurls = split /,/, $self->retrieve_data("iconurl");
    my @checkedplugs = split ',',$self->retrieve_data("checkedplug");
    my $pluginloop=[];

    foreach ( 0..$#reftypes ) {
        (my $imgid) = $iconurls[$_] =~ /([^\/]+)$/;
        $imgid=~s/\..*$//;
        push @$pluginloop,{
                    reftype => $reftypes[$_],
                    reflabel => $reflabels[$_],
                    alterserver => ($alterservers[$_] and $alterservers[$_] ne $kohaserver) ? $alterservers[$_] : '',
                    refquery => $refqueries[$_],
                    iconurl => $iconurls[$_],
                    imgid => $imgid,
                    checkedplug => $checkedplugs[$_],
                    };
    }
    # Get existing icons
    my $dirname = dirname(__FILE__);
    my $icondir = $dirname.'/EasySearch/icons/';
    my @icons;
    opendir (DIR, $icondir) or die $!;
    while (my $file = readdir(DIR)) {
         next unless -f $icondir.$file;
         (my $iconid = $file) =~ s/\..*$//;
         push @icons, { 'icon' => $self->get_plugin_http_path().'/icons/'.$file, 'iconid' => "_$iconid" };
    }
    closedir(DIR);
    $template->param(
        'pluginloop' => $pluginloop, 
        'kohaserver' => $kohaserver,
        'icons' => \@icons,
        'tooltip' => $self->retrieve_data('tooltip'),
        'menu' => $self->retrieve_data('menu'),
        'okconfig' => &existplugdir(),
    );
    print $cgi->header(-charset => 'utf-8' );
    print $template->output();
}

## This is the 'install' method. Any database tables or other setup that should
## be done when the plugin if first installed should be executed in this method.
## The installation method should always return true if the installation succeeded
## or false if it failed.
sub install() {
    my ( $self, $args ) = @_;
    my $params = { 
        'reftype' => "barcode,stocknumber,ppn",
        'reflabel' => "Code-barre,Numéro d'inventaire,PPN",
        'refquery' => "/cgi-bin/koha/plugins/run.pl?class=Koha::Plugin::PifPafPlug::EasySearch&amp;method=tool&amp;edititem=1&amp;barcode=,/cgi-bin/koha/plugins/run.pl?class=Koha::Plugin::PifPafPlug::EasySearch&amp;method=tool&amp;edititem=1&amp;stocknumber=,/cgi-bin/koha/catalogue/search.pl?q=ccl=ppn:",
        'iconurl' => "/plugin/Koha/Plugin/PifPafPlug/EasySearch/icons/barcode.png,/plugin/Koha/Plugin/PifPafPlug/EasySearch/icons/stocknumber.png,/plugin/Koha/Plugin/PifPafPlug/EasySearch/icons/ppn.png",
        'checkedplug' => "1,1,1",
    };
    $self->store_data($params);
    return 1;
}

## This method will be run just before the plugin files are deleted
## when a plugin is uninstalled. It is good practice to clean up
## after ourselves!
sub uninstall() {
    my ( $self, $args ) = @_;
    # Delete plugins menu if it exists.
    my $intranetuserjs = C4::Context->preference('intranetuserjs');
    $intranetuserjs =~ s!\/\* Koha EasySearch Plugin.*End of Koha EasySearch Plugin \*\/!!s;
    C4::Context->set_preference( 'intranetuserjs', $intranetuserjs );
    C4::Context->dbh->do("delete from plugin_data where plugin_class='Koha::Plugin::PifPafPlug::EasySearch'");
    return 1;
}

sub tool_step1 {
    my ( $self, $args ) = @_;
    my $cgi = $self->{'cgi'};
    my $template = $self->get_template({ file => 'tool-step1.tt' });
    my @checkedplugs = split ',',$self->retrieve_data("checkedplug");
    my @reftypes = split ',',$self->retrieve_data("reftype");
    my @reflabels = split ',',$self->retrieve_data("reflabel");
    my @refqueries = split ',',$self->retrieve_data("refquery");
    my @alterservers = split ',',$self->retrieve_data("alterserver");
    my $kohaserver = $self->retrieve_data("kohaserver");
    my $pluginloop;
    foreach ( 0..$#reftypes ) {
        my $server = $alterservers[$_] || $kohaserver;
        my $url = $server.$refqueries[$_]."%s";
        push @$pluginloop, {
            "reftype" => $reftypes[$_],
            "reflabel" => $reflabels[$_],
            "checkedplug" => $checkedplugs[$_],
            "url" => $url,
        };
    }
    
    $template->param(
                'tooltip' => $self->retrieve_data("tooltip"),
                'menu' => $self->retrieve_data("menu"),
                'pluginloop' => $pluginloop,
                'okconfig' => &existplugdir(),
                );

    print $cgi->header(-charset => 'utf-8' );
    print $template->output();
}

sub existplugdir {
    # check if initial config had been recorded
    my $dirname = dirname(__FILE__);
    my $plugindir = $dirname.'/EasySearch/searchplugins/';
    my $okconfig = -d $plugindir ? 1 : 0;
    return $okconfig;
}

1;
