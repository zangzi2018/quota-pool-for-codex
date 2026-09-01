using System.Windows;
using System.Windows.Threading;

namespace CodexAccounts.Companion;

public partial class MainWindow : Window
{
    private readonly CompanionState _state = new();
    private readonly DispatcherTimer _timer = new() { Interval = TimeSpan.FromMinutes(5) };
    private readonly CancellationTokenSource _lifetime = new();
    public MainWindow() { InitializeComponent(); DataContext = _state; _timer.Tick += async (_, _) => { if (_state.Pairing is not null && !_state.IsWorking) await Run(_state.SyncAsync); }; _timer.Start(); Loaded += async (_, _) => await _state.RunRelayConnectionAsync(_lifetime.Token); Closed += (_, _) => _lifetime.Cancel(); }
    private async void Pair_Click(object sender, RoutedEventArgs e) => await Run(_state.PairAsync);
    private async void Sync_Click(object sender, RoutedEventArgs e) => await Run(_state.SyncAsync);
    private void AddProfile_Click(object sender, RoutedEventArgs e) => _state.AddProfile();
    private void RemoveProfile_Click(object sender, RoutedEventArgs e) => _state.RemoveProfile(ProfilesGrid.SelectedItem as LocalProfile);
    private void Save_Click(object sender, RoutedEventArgs e) => _state.Save();
    private void RecordReset_Click(object sender, RoutedEventArgs e) => _state.RecordVerifiedGlobalReset();
    private async Task Run(Func<Task> action) { try { await action(); } catch (Exception error) { MessageBox.Show(this, error.Message, "Quota Pool", MessageBoxButton.OK, MessageBoxImage.Warning); } }
}
