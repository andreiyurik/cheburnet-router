<script>
	import { cn } from "$lib/utils.js";
	import { Separator } from "$lib/components/ui/separator/index.js";

	let {
		ref = $bindable(null),
		class: className,
		orientation = "vertical",
		...restProps
	} = $props();
</script>

<Separator
	bind:ref
	data-slot="button-group-separator"
	{orientation}
	class={cn("bg-input relative !m-0 self-stretch data-[orientation=vertical]:h-auto", className)}
	{...restProps}
/>
