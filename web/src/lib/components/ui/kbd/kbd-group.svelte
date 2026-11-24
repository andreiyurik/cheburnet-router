<script>
	import { cn } from "$lib/utils.js";

	let {
		ref = $bindable(null),
		class: className,
		children,
		...restProps
	} = $props();
</script>

<kbd
	bind:this={ref}
	data-slot="kbd-group"
	class={cn("inline-flex items-center gap-1", className)}
	{...restProps}
>
	{@render children?.()}
</kbd>
